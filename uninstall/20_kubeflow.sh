#!/usr/bin/env bash

# Kubeflow 제거 (install/20_kubeflow.sh의 역순)
# CP1(kubectl 접근 가능한 노드)에서 실행. MLflow가 설치되어 있다면 먼저 30번을 지울 것
# (MLflow가 이 안의 SeaweedFS/Gateway/Dashboard를 재사용하므로 순서가 반대면 orphan이 남음)
#
# 주의: kubeflow/community-distribution은 공식 uninstall 스크립트를 제공하지 않음
# (tests/ 디렉터리에 *_install.sh만 있고 대응하는 제거 스크립트가 없음).
# 그래서 이 스크립트는 "관련 네임스페이스 + CRD를 통째로 지우는" 실용적인 방식으로 접근함.
# 노드/커널 레벨 변경(예: istio-cni가 만든 iptables 룰)까지 완벽히 원복하진 않으므로,
# 완전히 깨끗한 상태가 필요하면 클러스터 자체를 재설치하는 편이 더 확실함.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"

require_root
setup_logging "uninstall_20_kubeflow"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[1/4] MLflow 잔존 확인 =="
if kubectl get namespace mlflow >/dev/null 2>&1; then
  die "namespace/mlflow이 아직 있습니다. MLflow가 Kubeflow의 SeaweedFS/Gateway를 쓰므로 uninstall/30_mlflow.sh를 먼저 실행하세요."
fi
green "MLflow 없음 확인, 계속 진행"

yellow "==[2/4] Namespace 삭제 =="
NAMESPACES=(
  kubeflow-user-example-com
  kubeflow
  katib
  kserve
  knative-eventing
  knative-serving
  oauth2-proxy
  auth
  cert-manager
  istio-system
)
for ns in "${NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl delete namespace "$ns" --ignore-not-found --timeout=180s
    green "namespace/${ns} 삭제 완료"
  fi
done

yellow "==[3/4] kube-system에 남는 Istio CNI 정리 =="
# istio-cni-node DaemonSet은 istio-system이 아니라 kube-system에 설치됨
kubectl delete daemonset istio-cni-node -n kube-system --ignore-not-found
kubectl delete configmap istio-cni-config -n kube-system --ignore-not-found

yellow "==[4/4] 잔여 CRD / ClusterRole 정리 =="
CRD_PATTERN='kubeflow\.org|istio\.io|cert-manager\.io|knative\.dev|serving\.kserve\.io|argoproj\.io|gateway\.networking\.k8s\.io'
REMAINING_CRDS="$(kubectl get crd -o name 2>/dev/null | grep -E "$CRD_PATTERN" || true)"
if [[ -n "$REMAINING_CRDS" ]]; then
  echo "$REMAINING_CRDS" | xargs -r kubectl delete --ignore-not-found
  green "잔여 CRD 정리 완료"
fi

REMAINING_CLUSTERROLES="$(kubectl get clusterrole -o name 2>/dev/null | grep -E 'kubeflow|istio|knative|kserve' || true)"
if [[ -n "$REMAINING_CLUSTERROLES" ]]; then
  echo "$REMAINING_CLUSTERROLES" | xargs -r kubectl delete --ignore-not-found
fi
REMAINING_CRBS="$(kubectl get clusterrolebinding -o name 2>/dev/null | grep -E 'kubeflow|istio|knative|kserve' || true)"
if [[ -n "$REMAINING_CRBS" ]]; then
  echo "$REMAINING_CRBS" | xargs -r kubectl delete --ignore-not-found
fi

echo
green "DONE: Kubeflow 제거 완료."
yellow "완전히 지워졌는지 최종 확인:"
echo "  kubectl get ns | grep -E 'kubeflow|istio|cert-manager|auth|oauth2-proxy|knative|katib|kserve'"
echo "  (출력이 없어야 정상)"
echo "Log: ${LOG_DIR}/uninstall_20_kubeflow.log"
