#!/usr/bin/env bash

# 목표 버전(versions.env) 대비 현재 설치 상태를 점검
# 분류: MISSING(미설치) / MISMATCH(버전 다름) / OK
#
# 사용:
#   ./check_versions.sh                # 기본 versions.env 사용
#   VERSIONS_FILE=/path/to.env ./check_versions.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-${SCRIPT_DIR}/../common/versions.env}"

green()  { echo -e "\033[1;32m$1\033[0m"; }
yellow() { echo -e "\033[1;33m$1\033[0m"; }
red()    { echo -e "\033[1;31m$1\033[0m"; }

[[ -f "$VERSIONS_FILE" ]] || { red "ERROR: versions file not found: $VERSIONS_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

have() { command -v "$1" >/dev/null 2>&1; }

MISSING_TOOLS=()
for t in kubectl; do have "$t" || MISSING_TOOLS+=("$t"); done
if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  yellow "WARNING: 다음 도구가 없어 일부 항목은 조회할 수 없습니다: ${MISSING_TOOLS[*]}"
fi

# Deployment/DaemonSet/StatefulSet의 첫 컨테이너 이미지 태그만 추출
img_tag() {
  local kind="$1" name="$2" ns="$3"
  have kubectl || { echo ""; return; }
  kubectl get "$kind" "$name" -n "$ns" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | awk -F: '{print $NF}'
}

probe() {
  local key="$1"
  case "$key" in
    OS_VERSION)                  lsb_release -rs 2>/dev/null ;;
    KERNEL_VERSION)               uname -r ;;
    K8S_VERSION)
      have kubectl && kubectl version 2>/dev/null \
        | grep -i "Server Version" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//' ;;
    CONTAINERD_VERSION)           containerd --version 2>/dev/null | awk '{print $3}' | sed 's/^v//' ;;
    CNI_CALICO_VERSION)           img_tag daemonset calico-node kube-system ;;

    GPU_OPERATOR_VERSION)
      have helm && helm list -n gpu-operator -o json 2>/dev/null \
        | grep -oE '"app_version":"[^"]*"' | head -1 | cut -d'"' -f4 ;;
    GPU_DRIVER_VERSION)           nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 ;;
    NVIDIA_CTK_VERSION)           dpkg-query -W -f='${Version}' nvidia-container-toolkit 2>/dev/null ;;
    NVIDIA_DEVICE_PLUGIN_VERSION) img_tag daemonset nvidia-device-plugin-daemonset gpu-operator ;;
    NVIDIA_NFD_VERSION)           img_tag daemonset nfd-worker gpu-operator ;;
    NVIDIA_GFD_VERSION)           img_tag daemonset gpu-feature-discovery gpu-operator ;;
    DCGM_VERSION)                 img_tag daemonset nvidia-dcgm gpu-operator ;;
    DCGM_EXPORTER_VERSION)        img_tag daemonset nvidia-dcgm-exporter gpu-operator ;;

    KUBEFLOW_PIPELINES_VERSION)   img_tag deployment ml-pipeline kubeflow ;;
    KUBEFLOW_TRAINER_VERSION)     img_tag deployment kubeflow-trainer-controller-manager kubeflow ;;
    TRAINING_OPERATOR_VERSION)    img_tag deployment training-operator kubeflow ;;
    KATIB_VERSION)                img_tag deployment katib-controller kubeflow ;;
    KSERVE_VERSION)                img_tag deployment kserve-controller-manager kserve ;;
    ISTIO_VERSION)                img_tag deployment istiod istio-system ;;
    CERT_MANAGER_VERSION)         img_tag deployment cert-manager cert-manager ;;
    DEX_VERSION)                  img_tag deployment dex auth ;;
    OAUTH2_PROXY_VERSION)         img_tag deployment oauth2-proxy oauth2-proxy ;;
    KNATIVE_VERSION)              img_tag deployment controller knative-serving ;;
    ARGO_WORKFLOWS_VERSION)       img_tag deployment workflow-controller kubeflow ;;
    KUSTOMIZE_VERSION)            kustomize version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 ;;

    MLFLOW_VERSION)               img_tag deployment mlflow-server mlflow ;;
    MYSQL_VERSION)                img_tag statefulset mlflow-mysql mlflow ;;
    *) echo "" ;;
  esac
}

# desired가 "x"로 끝나면 major.minor까지만, 아니면 앞부분 prefix 일치로 판정
status_of() {
  local desired="$1" actual="$2"
  [[ -z "$actual" ]] && { echo "MISSING"; return; }
  actual="${actual#v}"
  local want="${desired#v}"
  want="${want%.x}"
  [[ "$actual" == "$want"* ]] && echo "OK" || echo "MISMATCH"
}

# key:label
COMPONENTS=(
  "OS_VERSION:OS (Ubuntu)"
  "KERNEL_VERSION:Kernel"
  "K8S_VERSION:Kubernetes"
  "CONTAINERD_VERSION:containerd"
  "CNI_CALICO_VERSION:Calico"
  "GPU_OPERATOR_VERSION:GPU Operator"
  "GPU_DRIVER_VERSION:NVIDIA Driver"
  "NVIDIA_CTK_VERSION:NVIDIA Container Toolkit"
  "NVIDIA_DEVICE_PLUGIN_VERSION:NVIDIA Device Plugin"
  "NVIDIA_NFD_VERSION:NFD"
  "NVIDIA_GFD_VERSION:GPU Feature Discovery"
  "DCGM_VERSION:DCGM"
  "DCGM_EXPORTER_VERSION:DCGM Exporter"
  "ISTIO_VERSION:Istio"
  "CERT_MANAGER_VERSION:cert-manager"
  "DEX_VERSION:Dex"
  "OAUTH2_PROXY_VERSION:OAuth2 Proxy"
  "KNATIVE_VERSION:Knative Serving"
  "ARGO_WORKFLOWS_VERSION:Argo Workflows"
  "KUSTOMIZE_VERSION:Kustomize"
  "KUBEFLOW_PIPELINES_VERSION:Kubeflow Pipelines"
  "KUBEFLOW_TRAINER_VERSION:Kubeflow Trainer"
  "TRAINING_OPERATOR_VERSION:Training Operator"
  "KATIB_VERSION:Katib"
  "KSERVE_VERSION:KServe"
  "MLFLOW_VERSION:MLflow"
  "MYSQL_VERSION:MySQL (mlflow)"
)

MISSING_LIST=()
MISMATCH_LIST=()
OK_COUNT=0

printf "%-28s %-14s %-20s %s\n" "COMPONENT" "DESIRED" "INSTALLED" "STATUS"
printf "%-28s %-14s %-20s %s\n" "---------" "-------" "---------" "------"

for entry in "${COMPONENTS[@]}"; do
  key="${entry%%:*}"
  label="${entry#*:}"
  desired="${!key:-}"
  [[ -z "$desired" ]] && continue

  actual="$(probe "$key")"
  status="$(status_of "$desired" "$actual")"

  case "$status" in
    OK)       line=$(green  "$(printf '%-28s %-14s %-20s %s' "$label" "$desired" "${actual:-none}" "$status")") ;;
    MISSING)  line=$(red    "$(printf '%-28s %-14s %-20s %s' "$label" "$desired" "-" "$status")") ; MISSING_LIST+=("$label") ;;
    MISMATCH) line=$(yellow "$(printf '%-28s %-14s %-20s %s' "$label" "$desired" "${actual:-?}" "$status")") ; MISMATCH_LIST+=("$label (desired=$desired, actual=$actual)") ;;
  esac
  echo -e "$line"
  [[ "$status" == "OK" ]] && OK_COUNT=$((OK_COUNT + 1))
done

echo
yellow "==== Artifact Store 참고 ===="
echo "Kubeflow 26.03부터 MinIO가 SeaweedFS로 대체됨 (third-party 매니페스트에 minio 없음)."
echo "단, 하위호환을 위해 시크릿 이름(mlpipeline-minio-artifact)과 접근키/비밀키, S3 포트(9000)는 그대로 유지됨."
echo "-> MLflow는 seaweedfs.kubeflow.svc.cluster.local:9000 을 MinIO 대신 그대로 가리키면 됨 (별도 MinIO 재설치 불필요)."

echo
yellow "==== 요약 ===="
green  "OK       : ${OK_COUNT}"
red    "MISSING  : ${#MISSING_LIST[@]}"
if [[ ${#MISSING_LIST[@]} -gt 0 ]]; then
  printf '  - %s\n' "${MISSING_LIST[@]}"
fi
yellow "MISMATCH : ${#MISMATCH_LIST[@]}"
if [[ ${#MISMATCH_LIST[@]} -gt 0 ]]; then
  printf '  - %s\n' "${MISMATCH_LIST[@]}"
fi
