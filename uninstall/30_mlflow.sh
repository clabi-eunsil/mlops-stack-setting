#!/usr/bin/env bash

# MLflow 제거 (install/30_mlflow.sh의 역순)
# CP1(kubectl 접근 가능한 노드)에서 실행. Kubeflow/GPU Operator는 건드리지 않음.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"

require_root
setup_logging "uninstall_30_mlflow"

NS="mlflow"
WORKDIR="/root/mlflow-platform"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[1/5] Kubeflow Gateway 연동 해제 =="
kubectl delete virtualservice mlflow-server -n "$NS" --ignore-not-found

for POLICY in istio-ingressgateway-oauth2-proxy istio-ingressgateway-require-jwt; do
  if kubectl get authorizationpolicy "$POLICY" -n istio-system >/dev/null 2>&1; then
    # notPaths 배열 전체를 교체(replace)만 함 - rules의 다른 필드(when/from 등)는 건드리지 않음
    FILTERED_NOTPATHS="$(kubectl get authorizationpolicy "$POLICY" -n istio-system \
      -o jsonpath='{.spec.rules[0].to[0].operation.notPaths}' | python3 -c "
import json, sys
paths = json.load(sys.stdin)
print(json.dumps([p for p in paths if not p.startswith('/mlflow')]))
")"
    kubectl patch authorizationpolicy "$POLICY" -n istio-system --type=json -p="[
      {\"op\":\"replace\",\"path\":\"/spec/rules/0/to/0/operation/notPaths\",\"value\":${FILTERED_NOTPATHS}}
    ]"
    green "/mlflow 예외 제거: ${POLICY}"
  fi
done

yellow "==[2/5] Central Dashboard 사이드바 링크 제거 =="
if kubectl get configmap centraldashboard-config -n kubeflow >/dev/null 2>&1; then
  CURRENT_LINKS="$(kubectl get configmap centraldashboard-config -n kubeflow -o jsonpath='{.data.links}')"
  UPDATED_LINKS="$(echo "$CURRENT_LINKS" | python3 -c '
import json, sys
data = json.load(sys.stdin)
data["menuLinks"] = [l for l in data["menuLinks"] if l.get("link") != "/mlflow/"]
print(json.dumps(data))
')"
  kubectl patch configmap centraldashboard-config -n kubeflow --type=merge \
    -p "$(python3 -c "import json,sys; print(json.dumps({'data':{'links': sys.argv[1]}}))" "$UPDATED_LINKS")"
  kubectl rollout restart deployment/centraldashboard -n kubeflow
  green "사이드바 링크 제거 완료"
else
  yellow "centraldashboard-config 없음 (Kubeflow가 이미 삭제된 상태로 보임)"
fi

yellow "==[3/5] Helm 릴리스 제거 =="
if helm status mlflow -n "$NS" >/dev/null 2>&1; then
  helm uninstall mlflow -n "$NS" --wait --timeout 5m
  green "helm uninstall 완료"
else
  yellow "helm 릴리스 mlflow 없음"
fi

yellow "==[4/5] Namespace 삭제 (Secret 포함 전체 정리) =="
kubectl delete namespace "$NS" --ignore-not-found --timeout=120s
green "namespace/${NS} 삭제 완료"

yellow "==[5/5] 로컬 빌드 자산 정리 (선택) =="
if ctr -n k8s.io images ls -q 2>/dev/null | grep -q "mlflow-server"; then
  ctr -n k8s.io images ls -q | grep "mlflow-server" | xargs -r ctr -n k8s.io images rm
  green "containerd에서 mlflow-server 이미지 제거"
fi
yellow "자격증명/Dockerfile은 남겨둡니다: ${WORKDIR} (필요 없으면 수동으로 삭제하세요)"

echo
green "DONE: MLflow 제거 완료."
echo "Log: ${LOG_DIR}/uninstall_30_mlflow.log"
