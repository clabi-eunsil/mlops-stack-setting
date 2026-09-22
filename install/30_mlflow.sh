#!/usr/bin/env bash

# MLflow 설치 (mlflow 네임스페이스로 Kubeflow와 분리, Kubeflow의 SeaweedFS를 아티팩트 스토어로 재사용)
# CP1(kubectl 접근 가능한 노드)에서 20_kubeflow.sh 이후 실행
#
# 구조 (MinIO -> SeaweedFS로 교체):
#   Namespace: mlflow (Kubeflow와 수명주기/RBAC 분리)
#   Tracking DB: mlflow 전용 MySQL StatefulSet
#   Auth: MLflow native Basic Auth (SQLite + PVC로 영속화)
#   Artifact Store: kubeflow 네임스페이스의 SeaweedFS 재사용
#     - mlpipeline-minio-artifact 시크릿(접근키/비밀키)을 그대로 복사해 사용
#     - mlflow, datasets 두 버킷 생성 (datasets는 학습 데이터셋 공용 버킷, ~500GB 규모 전제)
#   노출: Kubeflow Gateway에 /mlflow 경로로 연결 + Central Dashboard 사이드바에 링크 추가
#
# 이미지: 커스텀 이미지를 직접 빌드함
# (python:3.11-slim + mlflow[auth]/pymysql/boto3 고정) -> docker build -> ctr import
# 이 클러스터는 k8s 런타임으로 containerd만 쓰므로, Docker는 오직 "이미지 빌드용 도구"로만 설치되고
# Kubernetes에는 전혀 등록되지 않음 (Docker: moby 네임스페이스, k8s: k8s.io 네임스페이스로 서로 분리)
# 02_containerd.sh가 이미 Docker 공식 apt repo를 등록해뒀으므로 docker-ce만 추가 설치하면 됨

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/versions.env"

require_root
setup_logging "30_mlflow"

NS="mlflow"
WORKDIR="/root/mlflow-platform"
SEAWEEDFS_ENDPOINT="http://seaweedfs.kubeflow.svc.cluster.local:9000"
MLFLOW_IMAGE_TAG="mlflow-server:${MLFLOW_VERSION}-auth-sqlite1"
MYSQL_IMAGE="mysql:${MYSQL_VERSION}"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " MLflow ${MLFLOW_VERSION} / MySQL ${MYSQL_VERSION}"
echo "========================================"

yellow "==[1/10] Namespace 생성 =="
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" istio-injection=enabled pod-security.kubernetes.io/enforce=baseline --overwrite
green "namespace/${NS} 준비 완료"

yellow "==[2/10] 자격증명 생성 =="
mkdir -p "${WORKDIR}/credentials"
chmod 700 "${WORKDIR}/credentials"
if [[ ! -f "${WORKDIR}/credentials/install.env" ]]; then
  umask 077
  cat > "${WORKDIR}/credentials/install.env" <<EOF
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 24)
MYSQL_PASSWORD=$(openssl rand -hex 24)
MLFLOW_ADMIN_USERNAME=admin
MLFLOW_ADMIN_PASSWORD=$(openssl rand -hex 20)
MLFLOW_FLASK_SECRET=$(openssl rand -hex 32)
EOF
  chmod 600 "${WORKDIR}/credentials/install.env"
  green "새 자격증명 생성: ${WORKDIR}/credentials/install.env"
else
  yellow "기존 자격증명 재사용: ${WORKDIR}/credentials/install.env"
fi
# shellcheck disable=SC1091
source "${WORKDIR}/credentials/install.env"

yellow "==[3/10] Kubernetes Secret 생성 =="
kubectl create secret generic mlflow-mysql-secret -n "$NS" \
  --from-literal=MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
  --from-literal=MYSQL_DATABASE=mlflow \
  --from-literal=MYSQL_USER=mlflow \
  --from-literal=MYSQL_PASSWORD="${MYSQL_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

MLFLOW_BACKEND_STORE_URI="mysql+pymysql://mlflow:${MYSQL_PASSWORD}@mlflow-mysql.${NS}.svc.cluster.local:3306/mlflow?charset=utf8mb4&ssl_disabled=true"
kubectl create secret generic mlflow-backend-secret -n "$NS" \
  --from-literal=MLFLOW_BACKEND_STORE_URI="${MLFLOW_BACKEND_STORE_URI}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Kubeflow 26.03의 SeaweedFS는 하위호환용으로 이 시크릿/키를 그대로 유지함 (MinIO 시절과 동일)
ARTIFACT_ACCESS_KEY="$(kubectl get secret mlpipeline-minio-artifact -n kubeflow -o jsonpath='{.data.accesskey}' | base64 -d)"
ARTIFACT_SECRET_KEY="$(kubectl get secret mlpipeline-minio-artifact -n kubeflow -o jsonpath='{.data.secretkey}' | base64 -d)"
kubectl create secret generic mlflow-artifact-secret -n "$NS" \
  --from-literal=AWS_ACCESS_KEY_ID="${ARTIFACT_ACCESS_KEY}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${ARTIFACT_SECRET_KEY}" \
  --from-literal=MLFLOW_S3_ENDPOINT_URL="${SEAWEEDFS_ENDPOINT}" \
  --dry-run=client -o yaml | kubectl apply -f -

cat > "${WORKDIR}/credentials/basic_auth.ini" <<EOF
[mlflow]
default_permission = READ
database_uri = sqlite:////var/lib/mlflow-auth/basic_auth.db
admin_username = ${MLFLOW_ADMIN_USERNAME}
admin_password = ${MLFLOW_ADMIN_PASSWORD}
authorization_function = mlflow.server.auth:authenticate_request_basic_auth
grant_default_workspace_access = false
auth_cache_ttl_seconds = 0
EOF
chmod 600 "${WORKDIR}/credentials/basic_auth.ini"
kubectl create secret generic mlflow-auth-config -n "$NS" \
  --from-file=basic_auth.ini="${WORKDIR}/credentials/basic_auth.ini" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic mlflow-auth-secret -n "$NS" \
  --from-literal=MLFLOW_FLASK_SERVER_SECRET_KEY="${MLFLOW_FLASK_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
green "Secret 5종 생성 완료"

yellow "==[4/10] Docker(이미지 빌드용) + crictl 설치 확인 =="
if ! command -v docker >/dev/null 2>&1; then
  # containerd.io는 02_containerd.sh에서 이미 설치+hold 되어 있으므로 여기서 재설치하지 않음
  apt-get update
  apt-get install -y docker-ce docker-ce-cli docker-buildx-plugin
fi
systemctl enable --now docker
docker version --format 'Docker: {{.Server.Version}}'

if ! command -v crictl >/dev/null 2>&1; then
  apt-get install -y cri-tools
fi
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF
green "Docker + crictl 준비 완료"

yellow "==[5/10] MLflow 이미지 빌드 =="
mkdir -p "${WORKDIR}/image"
cat > "${WORKDIR}/image/Dockerfile" <<EOF
FROM python:3.11-slim
ARG MLFLOW_VERSION=${MLFLOW_VERSION}
RUN python -m pip install --no-cache-dir "mlflow[auth]==\${MLFLOW_VERSION}" pymysql boto3
EXPOSE 5000
ENTRYPOINT ["mlflow", "server", "--host", "0.0.0.0", "--port", "5000", "--app-name", "basic-auth"]
EOF

if ! ctr -n k8s.io images ls -q | grep -q "docker.io/library/${MLFLOW_IMAGE_TAG}$"; then
  ( cd "${WORKDIR}/image" && docker build --build-arg MLFLOW_VERSION="${MLFLOW_VERSION}" -t "${MLFLOW_IMAGE_TAG}" . )
  docker save -o /tmp/mlflow-server.tar "${MLFLOW_IMAGE_TAG}"
  ctr -n k8s.io images import /tmp/mlflow-server.tar
  rm -f /tmp/mlflow-server.tar
  green "이미지 빌드 및 import 완료: ${MLFLOW_IMAGE_TAG}"
else
  yellow "이미지 이미 존재 (containerd k8s.io 네임스페이스): ${MLFLOW_IMAGE_TAG}"
fi
crictl images | grep mlflow-server || yellow "crictl에서 확인 안 됨 (ctr 기준으로는 정상 import됨)"

yellow "==[6/10] Helm 준비 =="
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version
green "Helm 준비 완료"

yellow "==[7/10] Helm 차트 생성 =="
CHART_DIR="${WORKDIR}/chart/mlflow-platform"
mkdir -p "${CHART_DIR}/templates"

cat > "${CHART_DIR}/Chart.yaml" <<EOF
apiVersion: v2
name: mlflow-platform
description: MLflow with dedicated MySQL tracking DB, SQLite auth DB, Kubeflow SeaweedFS artifact store
type: application
version: 0.1.0
appVersion: "${MLFLOW_VERSION}"
EOF

cat > "${CHART_DIR}/values.yaml" <<EOF
mlflow:
  image:
    repository: mlflow-server
    tag: "${MLFLOW_VERSION}-auth-sqlite1"
    pullPolicy: Never
  serviceAccount: mlflow-server
  service:
    port: 5000
  authPersistence:
    size: 1Gi
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits: { cpu: "2", memory: 2Gi }

mysql:
  image:
    repository: mysql
    tag: "${MYSQL_VERSION}"
  serviceAccount: mlflow-mysql
  persistence:
    size: 20Gi
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits: { cpu: "2", memory: 2Gi }

artifact:
  buckets: ["mlflow", "datasets"]
  endpoint: ${SEAWEEDFS_ENDPOINT}

kubeflow:
  namespace: kubeflow
EOF

cat > "${CHART_DIR}/templates/entrypoint-configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mlflow-entrypoint
  namespace: {{ .Release.Namespace }}
data:
  entrypoint.py: |
    import os
    import time

    from sqlalchemy import create_engine, text

    uri = os.environ["MLFLOW_BACKEND_STORE_URI"]
    last_error = None

    for attempt in range(120):
        try:
            engine = create_engine(uri, pool_pre_ping=True, connect_args={"connect_timeout": 5})
            with engine.connect() as connection:
                connection.execute(text("SELECT 1"))
            engine.dispose()
            print("MySQL is ready.", flush=True)
            break
        except Exception as exc:
            last_error = exc
            print(f"Waiting for MySQL ({attempt + 1}/120): {exc}", flush=True)
            time.sleep(5)
    else:
        raise SystemExit(f"MySQL did not become ready: {last_error}")

    os.execvp("mlflow", [
        "mlflow", "server",
        "--host", "0.0.0.0",
        "--port", "5000",
        "--app-name", "basic-auth",
        "--backend-store-uri", uri,
        "--artifacts-destination", f"s3://{os.environ['MLFLOW_ARTIFACT_BUCKET']}/",
        "--serve-artifacts",
        "--workers", "1",
    ])
EOF

cat > "${CHART_DIR}/templates/serviceaccounts.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.mlflow.serviceAccount }}
  namespace: {{ .Release.Namespace }}
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.mysql.serviceAccount }}
  namespace: {{ .Release.Namespace }}
automountServiceAccountToken: false
EOF

cat > "${CHART_DIR}/templates/mysql.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mlflow-mysql-config
  namespace: {{ .Release.Namespace }}
data:
  mlflow.cnf: |
    [mysqld]
    skip-log-bin
    character-set-server=utf8mb4
    collation-server=utf8mb4_unicode_ci
    max_connections=200
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow-mysql-headless
  namespace: {{ .Release.Namespace }}
  labels: { app: mlflow-mysql }
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: { app: mlflow-mysql }
  ports:
    - { name: tcp-mysql, port: 3306, targetPort: mysql }
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow-mysql
  namespace: {{ .Release.Namespace }}
  labels: { app: mlflow-mysql }
spec:
  type: ClusterIP
  selector: { app: mlflow-mysql }
  ports:
    - { name: tcp-mysql, port: 3306, targetPort: mysql }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mlflow-mysql
  namespace: {{ .Release.Namespace }}
  labels: { app: mlflow-mysql }
spec:
  serviceName: mlflow-mysql-headless
  replicas: 1
  selector:
    matchLabels: { app: mlflow-mysql }
  template:
    metadata:
      labels: { app: mlflow-mysql }
    spec:
      serviceAccountName: {{ .Values.mysql.serviceAccount }}
      terminationGracePeriodSeconds: 30
      containers:
        - name: mysql
          image: "{{ .Values.mysql.image.repository }}:{{ .Values.mysql.image.tag }}"
          ports:
            - { name: mysql, containerPort: 3306 }
          envFrom:
            - secretRef: { name: mlflow-mysql-secret }
          volumeMounts:
            - { name: mysql-data, mountPath: /var/lib/mysql }
            - { name: mysql-config, mountPath: /etc/mysql/conf.d/mlflow.cnf, subPath: mlflow.cnf, readOnly: true }
          startupProbe:
            exec:
              command: ["sh", "-ec", 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD"']
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 60
          readinessProbe:
            exec:
              command: ["sh", "-ec", 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD"']
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            exec:
              command: ["sh", "-ec", 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD"']
            initialDelaySeconds: 60
            periodSeconds: 20
            failureThreshold: 6
          resources:
            {{- toYaml .Values.mysql.resources | nindent 12 }}
      volumes:
        - name: mysql-config
          configMap: { name: mlflow-mysql-config }
  volumeClaimTemplates:
    - metadata:
        name: mysql-data
        labels: { app: mlflow-mysql }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: {{ .Values.mysql.persistence.size }}
EOF

cat > "${CHART_DIR}/templates/mlflow-deployment.yaml" <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mlflow-auth-data
  namespace: {{ .Release.Namespace }}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: {{ .Values.mlflow.authPersistence.size }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlflow-server
  namespace: {{ .Release.Namespace }}
  labels: { app: mlflow-server }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels: { app: mlflow-server }
  template:
    metadata:
      labels: { app: mlflow-server }
      annotations:
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      serviceAccountName: {{ .Values.mlflow.serviceAccount }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: mlflow
          image: "{{ .Values.mlflow.image.repository }}:{{ .Values.mlflow.image.tag }}"
          imagePullPolicy: {{ .Values.mlflow.image.pullPolicy }}
          command: ["python", "/entrypoint/entrypoint.py"]
          ports:
            - { name: http, containerPort: 5000 }
          envFrom:
            - secretRef: { name: mlflow-artifact-secret }
          env:
            - { name: HOME, value: /tmp }
            - { name: MLFLOW_ARTIFACT_BUCKET, value: {{ (first .Values.artifact.buckets) | quote }} }
            - name: MLFLOW_BACKEND_STORE_URI
              valueFrom:
                secretKeyRef: { name: mlflow-backend-secret, key: MLFLOW_BACKEND_STORE_URI }
            - { name: MLFLOW_AUTH_CONFIG_PATH, value: /etc/mlflow-auth/basic_auth.ini }
            - name: MLFLOW_FLASK_SERVER_SECRET_KEY
              valueFrom:
                secretKeyRef: { name: mlflow-auth-secret, key: MLFLOW_FLASK_SERVER_SECRET_KEY }
            - { name: MLFLOW_WEBHOOK_ALLOW_PRIVATE_IPS, value: "true" }
          volumeMounts:
            - { name: entrypoint, mountPath: /entrypoint }
            - { name: auth-data, mountPath: /var/lib/mlflow-auth }
            - { name: auth-config, mountPath: /etc/mlflow-auth, readOnly: true }
            - { name: tmp, mountPath: /tmp }
          startupProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 10
            failureThreshold: 90
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 20
            failureThreshold: 6
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
          resources:
            {{- toYaml .Values.mlflow.resources | nindent 12 }}
      volumes:
        - name: entrypoint
          configMap: { name: mlflow-entrypoint }
        - name: auth-data
          persistentVolumeClaim: { claimName: mlflow-auth-data }
        - name: auth-config
          secret: { secretName: mlflow-auth-config }
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow-server
  namespace: {{ .Release.Namespace }}
  labels: { app: mlflow-server }
spec:
  selector: { app: mlflow-server }
  ports:
    - { name: http, port: {{ .Values.mlflow.service.port }}, targetPort: http }
EOF

cat > "${CHART_DIR}/templates/policies.yaml" <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: mlflow-mysql-allow-mlflow-server
  namespace: {{ .Release.Namespace }}
spec:
  selector:
    matchLabels: { app: mlflow-mysql }
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/{{ .Release.Namespace }}/sa/{{ .Values.mlflow.serviceAccount }}"]
      to:
        - operation: { ports: ["3306"] }
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: mlflow-server-allow
  namespace: {{ .Release.Namespace }}
spec:
  selector:
    matchLabels: { app: mlflow-server }
  action: ALLOW
  rules:
    - to:
        - operation: { ports: ["5000"] }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: seaweedfs-allow-mlflow
  namespace: {{ .Values.kubeflow.namespace }}
spec:
  podSelector:
    matchLabels: { app: seaweedfs }
  policyTypes: ["Ingress"]
  ingress:
    # mlflow-server뿐 아니라 mlflow-bucket-init 같은 일회성 Job도 접근해야 하므로
    # 특정 pod 라벨이 아니라 mlflow 네임스페이스 전체를 허용 (네임스페이스 자체가 격리 경계)
    #
    # 포트는 Service 포트(9000)가 아니라 실제 Pod가 듣는 targetPort(8333)를 적어야 함.
    # NetworkPolicy의 ports는 Pod 기준으로 매칭되므로 Service 포트 번호를 적으면
    # 아무 트래픽도 매칭되지 않아 계속 막힌 것처럼 동작함.
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: {{ .Release.Namespace }} }
      ports:
        - { protocol: TCP, port: 8333 }
EOF

cat > "${CHART_DIR}/templates/bucket-init-job.yaml" <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: mlflow-bucket-init
  namespace: {{ .Release.Namespace }}
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "10"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 3
  template:
    metadata:
      annotations:
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      serviceAccountName: {{ .Values.mlflow.serviceAccount }}
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
      containers:
        - name: create-buckets
          image: "{{ .Values.mlflow.image.repository }}:{{ .Values.mlflow.image.tag }}"
          imagePullPolicy: {{ .Values.mlflow.image.pullPolicy }}
          command: ["python", "-c"]
          args:
            - |
              import os
              import boto3

              client = boto3.client(
                  's3',
                  endpoint_url=os.environ['MLFLOW_S3_ENDPOINT_URL'],
                  aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
                  aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
              )
              existing = {b['Name'] for b in client.list_buckets().get('Buckets', [])}
              for bucket in {{ .Values.artifact.buckets | toJson }}:
                  if bucket in existing:
                      print(f'Bucket already exists: {bucket}')
                  else:
                      client.create_bucket(Bucket=bucket)
                      print(f'Bucket created: {bucket}')
          env:
            - { name: HOME, value: /tmp }
          envFrom:
            - secretRef: { name: mlflow-artifact-secret }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
EOF

cat > "${CHART_DIR}/templates/virtualservice.yaml" <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mlflow-server
  namespace: {{ .Release.Namespace }}
spec:
  gateways:
    - {{ .Values.kubeflow.namespace }}/kubeflow-gateway
  hosts: ["*"]
  http:
    - name: mlflow-root-redirect
      match:
        - uri: { exact: /mlflow }
      redirect:
        uri: /mlflow/
    - name: mlflow-route
      match:
        - uri: { prefix: /mlflow/ }
      route:
        - destination:
            host: mlflow-server.{{ .Release.Namespace }}.svc.cluster.local
            port:
              number: {{ .Values.mlflow.service.port }}
EOF

helm lint "${CHART_DIR}"
green "Helm 차트 생성 완료: ${CHART_DIR}"

yellow "==[8/10] Helm 설치 =="
helm upgrade --install mlflow "${CHART_DIR}" \
  --namespace "${NS}" \
  --wait --timeout 15m
kubectl wait --for=condition=Complete job/mlflow-bucket-init -n "$NS" --timeout=180s
green "MLflow 설치 완료 (mlflow, datasets 버킷 포함)"

yellow "==[9/10] Kubeflow Gateway 연동 =="
# Kubeflow 기본 OAuth2/JWT 정책은 전체 경로를 인증 대상으로 삼으므로 /mlflow만 예외 처리
# (MLflow 자체 Basic Auth로 인증하므로 이중 인증을 막기 위함)
for POLICY in istio-ingressgateway-oauth2-proxy istio-ingressgateway-require-jwt; do
  CURRENT_NOTPATHS="$(kubectl get authorizationpolicy "$POLICY" -n istio-system -o jsonpath='{.spec.rules[0].to[0].operation.notPaths}' 2>/dev/null || echo '[]')"
  if [[ "$CURRENT_NOTPATHS" != *"/mlflow"* ]]; then
    kubectl patch authorizationpolicy "$POLICY" -n istio-system --type=json -p='[
      {"op":"add","path":"/spec/rules/0/to/0/operation/notPaths/-","value":"/mlflow"},
      {"op":"add","path":"/spec/rules/0/to/0/operation/notPaths/-","value":"/mlflow/*"},
      {"op":"add","path":"/spec/rules/0/to/0/operation/notPaths/-","value":"/mlflow/**"}
    ]'
    green "패치 완료: ${POLICY}"
  else
    yellow "이미 /mlflow 예외 있음: ${POLICY}"
  fi
done

yellow "==[10/10] Central Dashboard 사이드바에 MLflow 링크 추가 =="
CURRENT_LINKS="$(kubectl get configmap centraldashboard-config -n kubeflow -o jsonpath='{.data.links}')"
if ! echo "$CURRENT_LINKS" | grep -q '"/mlflow/"'; then
  UPDATED_LINKS="$(echo "$CURRENT_LINKS" | python3 -c '
import json, sys
data = json.load(sys.stdin)
data["menuLinks"].append({"type": "item", "link": "/mlflow/", "text": "MLflow", "icon": "assessment"})
print(json.dumps(data))
')"
  kubectl patch configmap centraldashboard-config -n kubeflow --type=merge \
    -p "$(python3 -c "import json,sys; print(json.dumps({'data':{'links': sys.argv[1]}}))" "$UPDATED_LINKS")"
  kubectl rollout restart deployment/centraldashboard -n kubeflow
  green "사이드바 링크 추가 완료"
else
  yellow "이미 사이드바에 MLflow 링크 있음"
fi

kubectl rollout status deployment/mlflow-server -n "$NS" --timeout=300s

echo
green "DONE: MLflow 설치 완료."
echo "관리자 계정: ${MLFLOW_ADMIN_USERNAME} / (비밀번호: ${WORKDIR}/credentials/install.env 확인)"
echo "접속: Kubeflow Dashboard 사이드바 'MLflow' 또는 http://<kubeflow-host>/mlflow/"
echo "자격증명 파일: ${WORKDIR}/credentials/install.env (root 전용, 안전하게 백업할 것)"
echo "Log: ${LOG_DIR}/30_mlflow.log"
