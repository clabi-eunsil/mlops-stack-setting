#!/usr/bin/env bash

# Kubeflow(+MLflow, /mlflow 경로 공유)를 NodePort로 노출 + SeaweedFS S3 API도 NodePort로 노출
# CP1(kubectl 접근 가능한 노드)에서 20_kubeflow.sh 이후 아무 때나 실행 가능 (선택 사항)
#
# port-forward 없이 서버 IP:포트로 바로 접속하고 싶을 때 사용.
# HTTP(비TLS) NodePort이므로 웹앱들의 secure-cookie 설정도 같이 꺼야 로그인이 됨.
#
# 포트 지정 (우선순위: --flag 인자 > 환경변수 > 기본값):
#   sudo bash 21_kubeflow_nodeport.sh --kubeflow-nodeport=31080 --kubeflow-status-nodeport=31021 --seaweedfs-s3-nodeport=31900
#   또는 sudo KUBEFLOW_NODEPORT=31080 bash 21_kubeflow_nodeport.sh
#
# 주의: 이렇게 열면 기본 계정(user@example.com/12341234)으로 외부에서 바로 접근 가능해짐.
#       내부망/방화벽 뒤가 아니라면 비밀번호부터 바꿀 것.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"

require_root
setup_logging "21_kubeflow_nodeport"

KUBEFLOW_NODEPORT="${KUBEFLOW_NODEPORT:-30080}"
KUBEFLOW_STATUS_NODEPORT="${KUBEFLOW_STATUS_NODEPORT:-30021}"
SEAWEEDFS_S3_NODEPORT="${SEAWEEDFS_S3_NODEPORT:-30900}"

for a in "$@"; do
  case "$a" in
    --kubeflow-nodeport=*)        KUBEFLOW_NODEPORT="${a#--kubeflow-nodeport=}" ;;
    --kubeflow-status-nodeport=*) KUBEFLOW_STATUS_NODEPORT="${a#--kubeflow-status-nodeport=}" ;;
    --seaweedfs-s3-nodeport=*)    SEAWEEDFS_S3_NODEPORT="${a#--seaweedfs-s3-nodeport=}" ;;
    *) die "알 수 없는 인자: $a" ;;
  esac
done

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[1/4] istio-ingressgateway를 NodePort로 변경 =="
kubectl get svc istio-ingressgateway -n istio-system -o yaml > /root/istio-ingressgateway-before-nodeport.yaml
kubectl patch svc istio-ingressgateway -n istio-system --type=merge -p "$(cat <<EOF
{
  "spec": {
    "type": "NodePort",
    "ports": [
      {"name": "status-port", "protocol": "TCP", "port": 15021, "targetPort": 15021, "nodePort": ${KUBEFLOW_STATUS_NODEPORT}},
      {"name": "http2", "protocol": "TCP", "port": 80, "targetPort": 8080, "nodePort": ${KUBEFLOW_NODEPORT}}
    ]
  }
}
EOF
)"
green "istio-ingressgateway NodePort 설정 완료 (백업: /root/istio-ingressgateway-before-nodeport.yaml)"

yellow "==[2/4] 웹앱 secure-cookie 비활성화 (HTTP 접속이므로 필요) =="
for DEPLOY in jupyter-web-app-deployment tensorboards-web-app-deployment volumes-web-app-deployment; do
  if kubectl get deployment "$DEPLOY" -n kubeflow >/dev/null 2>&1; then
    kubectl set env "deployment/${DEPLOY}" -n kubeflow APP_SECURE_COOKIES=false
    kubectl rollout status "deployment/${DEPLOY}" -n kubeflow --timeout=180s
  fi
done
green "웹앱 secure-cookie 비활성화 완료"

yellow "==[3/4] oauth2-proxy secure-cookie 비활성화 =="
kubectl get deployment oauth2-proxy -n oauth2-proxy -o json \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
args = d['spec']['template']['spec']['containers'][0]['args']
d['spec']['template']['spec']['containers'][0]['args'] = [
    '--cookie-secure=false' if a.startswith('--cookie-secure=') else a for a in args
]
print(json.dumps(d))
" | kubectl apply -f -
kubectl rollout status deployment/oauth2-proxy -n oauth2-proxy --timeout=180s
green "oauth2-proxy secure-cookie 비활성화 완료"

yellow "==[4/4] SeaweedFS S3 API NodePort 노출 =="
# 기존 ClusterIP 서비스(seaweedfs)는 그대로 두고, S3 API 포트만 별도 NodePort 서비스로 추가 노출
# (기존 서비스를 NodePort로 바꾸면 포트가 7개라 전부 nodePort를 지정해야 해서 번거롭고,
#  클러스터 내부에서 seaweedfs.kubeflow.svc.cluster.local로 쓰는 다른 서비스에 영향 없게 하기 위함)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: seaweedfs-s3-nodeport
  namespace: kubeflow
spec:
  type: NodePort
  selector:
    app: seaweedfs
  ports:
    - name: s3
      port: 9000
      targetPort: 8333
      nodePort: ${SEAWEEDFS_S3_NODEPORT}
EOF
green "SeaweedFS S3 API NodePort 노출 완료"

NODE_IP="$(hostname -I | awk '{print $1}')"
echo
green "DONE: NodePort 노출 완료."
echo "Kubeflow Dashboard : http://${NODE_IP}:${KUBEFLOW_NODEPORT}"
echo "MLflow             : http://${NODE_IP}:${KUBEFLOW_NODEPORT}/mlflow/"
echo "SeaweedFS S3 API   : http://${NODE_IP}:${SEAWEEDFS_S3_NODEPORT} (접근키: mlpipeline-minio-artifact 시크릿 참고)"
red "주의: 기본 로그인(user@example.com / 12341234)을 그대로 두면 외부에서 이 정보로 접속 가능합니다. 반드시 변경하세요."
echo "Log: ${LOG_DIR}/21_kubeflow_nodeport.log"
