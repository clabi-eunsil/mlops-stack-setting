#!/usr/bin/env bash

# Kubeflow 26.03(kubeflow/community-distribution, release-26.03) 설치
# CP1(kubectl 접근 가능한 노드)에서 1회 실행
#
# 구성 순서는 저장소 README의 "Install Individual Components" 절차를 그대로 따름
# (https://github.com/kubeflow/community-distribution/blob/release-26.03/README.md)
#
# Artifact Store 참고:
# - Kubeflow 26.03부터 MinIO가 SeaweedFS로 대체됨. 단, 하위호환을 위해
#   시크릿 이름(mlpipeline-minio-artifact)/접근키(minio/minio123)/9000번 포트는 그대로 유지되므로
#   별도 조치 없이 기본 설치만으로 MLflow와 공유 가능한 S3 엔드포인트가 생김.
#   (MLflow 연동은 30_mlflow.sh에서 seaweedfs.kubeflow.svc.cluster.local:9000 을 사용)
#
# 옵션 (환경변수):
#   INSTALL_KSERVE=0   Knative+KServe(모델 서빙)를 건너뜀 (기본: 1, 설치함)
#   INSTALL_TRAINING_OPERATOR_V1=0   구버전 Training Operator(v1)를 건너뜀 (기본: 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/versions.env"

require_root
setup_logging "20_kubeflow"

INSTALL_KSERVE="${INSTALL_KSERVE:-1}"
INSTALL_TRAINING_OPERATOR_V1="${INSTALL_TRAINING_OPERATOR_V1:-1}"
KF_DIR="${KF_DIR:-/root/kubeflow-community-distribution}"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " Repo ref: ${KUBEFLOW_DISTRIBUTION_REPO}@${KUBEFLOW_DISTRIBUTION_REF}"
echo "========================================"

yellow "==[1/5] inotify 커널 설정 =="
# Kubeflow 공식 매니페스트 권장값 (Pod가 많아지면 기본값으로는 부족)
cat > /etc/sysctl.d/99-kubeflow.conf <<'EOF'
fs.inotify.max_user_instances=2280
fs.inotify.max_user_watches=1255360
EOF
sysctl --system | grep -E "max_user_instances|max_user_watches" || true
green "inotify 설정 완료"

yellow "==[2/5] kustomize ${KUSTOMIZE_VERSION} 설치 =="
if ! command -v kustomize >/dev/null 2>&1 || [[ "$(kustomize version 2>/dev/null)" != *"${KUSTOMIZE_VERSION}"* ]]; then
  TMP_DIR="$(mktemp -d)"
  ASSET="kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
  curl -fsSL -o "${TMP_DIR}/${ASSET}" \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/${ASSET}"
  tar -xzf "${TMP_DIR}/${ASSET}" -C "${TMP_DIR}"
  install -m 0755 "${TMP_DIR}/kustomize" /usr/local/bin/kustomize
  rm -rf "${TMP_DIR}"
fi
kustomize version
green "kustomize 준비 완료"

yellow "==[3/5] kubeflow/community-distribution clone (${KUBEFLOW_DISTRIBUTION_REF}) =="
if [[ ! -d "${KF_DIR}/.git" ]]; then
  git clone --branch "${KUBEFLOW_DISTRIBUTION_REF}" --depth 1 \
    "https://github.com/${KUBEFLOW_DISTRIBUTION_REPO}.git" "${KF_DIR}"
else
  CURRENT_REF="$(cd "${KF_DIR}" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if [[ "$CURRENT_REF" != "${KUBEFLOW_DISTRIBUTION_REF}" ]]; then
    yellow "WARNING: ${KF_DIR}가 이미 존재하지만 브랜치가 다릅니다 (현재: ${CURRENT_REF}, 목표: ${KUBEFLOW_DISTRIBUTION_REF})"
  else
    yellow "이미 clone됨: ${KF_DIR} (${CURRENT_REF})"
  fi
fi
cd "${KF_DIR}"

# CRD 등록 직후 CR 적용이 실패하는 건 공식 문서에도 나오는 정상 케이스 -> 재시도
apply_kustomize() {
  local path="$1"
  local tries=0
  until kustomize build "$path" | kubectl apply -f -; do
    tries=$((tries + 1))
    [[ $tries -ge 5 ]] && die "kustomize apply 실패 (5회 재시도): $path"
    yellow "재시도 중 (${tries}/5): $path"
    sleep 15
  done
}

yellow "==[4/5] 컴포넌트 설치 =="

echo "-- Kubeflow Namespace --"
apply_kustomize common/kubeflow-namespace/base

echo "-- cert-manager --"
./tests/cert_manager_install.sh

echo "-- Istio (CNI) --"
./tests/istio-cni_install.sh

echo "-- OAuth2 Proxy (m2m-dex-only) --"
apply_kustomize common/oauth2-proxy/overlays/m2m-dex-only
kubectl wait --for=condition=Ready pod -l 'app.kubernetes.io/name=oauth2-proxy' --timeout=180s -n oauth2-proxy

echo "-- Kubeflow Istio Resources (Gateway) --"
apply_kustomize common/istio/kubeflow-istio-resources/base

echo "-- Multi-tenancy (Profiles + KFAM) --"
./tests/multi_tenancy_install.sh

echo "-- Dex --"
./tests/dex_install.sh

echo "-- Central Dashboard --"
./tests/central_dashboard_install.sh

echo "-- Admission Webhook (PodDefaults) --"
apply_kustomize applications/admission-webhook/upstream/overlays/cert-manager

if [[ "$INSTALL_KSERVE" == "1" ]]; then
  echo "-- Knative Serving --"
  ./tests/knative_install.sh
  echo "-- KServe --"
  ./tests/kserve_install.sh
else
  yellow "INSTALL_KSERVE=0 -> Knative/KServe 건너뜀"
fi

echo "-- Kubeflow Pipelines (SeaweedFS/MySQL 포함) --"
# SeaweedFS는 별도 단계가 아니라 이 안에 번들로 같이 설치됨
# (applications/pipeline/upstream/third-party/seaweedfs) - kubeflow 네임스페이스에
# Service "seaweedfs", Secret "mlpipeline-minio-artifact" 가 이 단계에서 함께 생성됨
./tests/pipelines_install.sh

echo "-- Katib --"
./tests/katib_install.sh

echo "-- Notebook Controller --"
apply_kustomize applications/jupyter/notebook-controller/upstream/overlays/kubeflow
echo "-- Jupyter Web App --"
apply_kustomize applications/jupyter/jupyter-web-app/upstream/overlays/istio
echo "-- PVC Viewer Controller --"
apply_kustomize applications/pvcviewer-controller/upstream/base
echo "-- Volumes Web App --"
./tests/volumes_web_application_install.sh
echo "-- TensorBoard Web App --"
apply_kustomize applications/tensorboard/tensorboards-web-app/upstream/overlays/istio
echo "-- TensorBoard Controller --"
apply_kustomize applications/tensorboard/tensorboard-controller/upstream/overlays/kubeflow

if [[ "$INSTALL_TRAINING_OPERATOR_V1" == "1" ]]; then
  echo "-- Training Operator (v1, 기존 워크로드 호환용) --"
  ./tests/training_operator_install.sh
else
  yellow "INSTALL_TRAINING_OPERATOR_V1=0 -> Training Operator v1 건너뜀"
fi

echo "-- Trainer (v2) --"
./tests/trainer_install.sh

echo "-- 기본 사용자 Namespace --"
KF_PROFILE=kubeflow-user-example-com ./tests/kubeflow_profile_install.sh

yellow "==[5/5] 최종 확인 =="
kubectl get pods -A | grep -Ev "Running|Completed" || green "모든 Pod가 Running/Completed 상태"

echo
green "DONE: Kubeflow 설치 완료."
yellow "접속 방법:"
echo "  kubectl port-forward --address=127.0.0.1 svc/istio-ingressgateway -n istio-system 8080:80"
echo "  브라우저: http://localhost:8080  (user@example.com / 12341234 — 반드시 변경할 것)"
yellow "Artifact Store: MinIO 대신 SeaweedFS(seaweedfs.kubeflow.svc.cluster.local:9000)가 설치됨."
echo "  시크릿 mlpipeline-minio-artifact, 접근키 minio/minio123 는 그대로라 MLflow에서 재사용 가능."
echo "Log: ${LOG_DIR}/20_kubeflow.log"
