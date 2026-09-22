# mlops-stack-setting

베어메탈 Ubuntu 서버를 GPU 기반 MLOps 플랫폼(Kubernetes + Kubeflow + MLflow)까지 한 번에 구성하는 자동화 스크립트 모음입니다. 서버 몇 대의 IP만 입력하면 OS 기본 설정부터 Kubernetes 클러스터, GPU Operator, Kubeflow, MLflow까지 순서대로 설치되며, 각 구성 요소는 개별적으로 설치/제거할 수도 있습니다.

## 구성 요소 및 버전

| 구성 요소 | 버전 |
| --- | --- |
| OS | Ubuntu 24.04 LTS |
| Kernel | 6.8 계열 |
| Kubernetes | 1.36.x (kubeadm) |
| containerd | 2.2.x |
| CNI | Calico 3.32.x |
| GPU Operator | 26.7.0 (드라이버 제외, container-toolkit/device-plugin/NFD/DCGM 관리) |
| NVIDIA Driver | 595.91.07 (호스트에 직접 설치, `nvidia-smi`가 호스트에서 바로 동작) |
| Kubeflow | 26.03 (kustomize 기반, Istio 1.29 / cert-manager 1.19.4 / Dex 2.45.0 / KFP 2.16.0 / KServe 0.16.0 등) |
| MLflow | 3.13.0 (Helm, 전용 MySQL 8.4 트래킹 DB) |

정확한 목표 버전은 [`common/versions.env`](common/versions.env) 한 곳에서 관리하며, [`audit/check_versions.sh`](audit/check_versions.sh)로 실제 설치 상태와 비교할 수 있습니다.

## 디렉터리 구조

```md
common/
  lib.sh          공통 함수 (색상 로그, root 체크, 로깅)
  ssh.sh          bastion 전용 SSH 부트스트랩/원격실행 함수
  versions.env    목표 버전 정의 (모든 install/uninstall 스크립트가 참조)

install/
  00_os_base.sh           OS 초기 설정 (패키지, chrony, SSH keepalive)
  01_k8s_prereq.sh        커널 모듈 / sysctl / swap 비활성화
  02_containerd.sh        containerd 설치 및 설정
  03_kubeadm_packages.sh  kubeadm / kubelet / kubectl 설치
  04_ha_setup.sh          keepalived + haproxy (Control Plane 다중화, VIP)
  05_kubeadm_bootstrap.sh kubeadm init/join + Calico CNI 설치
  09_nvidia_driver.sh     NVIDIA 드라이버 호스트 설치 (GPU 노드 전용)
  10_gpu_operator.sh      NVIDIA GPU Operator (Helm, 드라이버 제외)
  20_kubeflow.sh          Kubeflow 전체 스택 (kustomize)
  30_mlflow.sh            MLflow (Helm, Kubeflow의 SeaweedFS 아티팩트 스토어 재사용)

uninstall/
  00_k8s_reset.sh         클러스터 전체 초기화 (모든 노드를 bare Ubuntu에 가깝게 되돌림)
  09_nvidia_driver.sh     NVIDIA 드라이버 제거 (GPU 노드 전용)
  10_gpu_operator.sh      GPU Operator 제거
  20_kubeflow.sh          Kubeflow 제거
  30_mlflow.sh            MLflow 제거

bastion/
  cluster.env.example     클러스터 설정 템플릿
  run.sh                  전체 설치 오케스트레이터
  uninstall.sh            선택적 제거 오케스트레이터

audit/
  check_versions.sh       설치 상태 vs 목표 버전 점검 도구
  bare_ubuntu_check.sh    노드가 bare Ubuntu 상태로 잘 돌아갔는지 점검 (k8s/Docker/NVIDIA 흔적 확인)
```

`install/`, `uninstall/`의 각 스크립트는 대상 노드에 SSH로 복사되어 `sudo bash`로 단독 실행되며, 필요하면 특정 스크립트 하나만 수동으로 실행할 수도 있습니다.

## 빠른 시작

```bash
cp bastion/cluster.env.example bastion/cluster.env
vi bastion/cluster.env   # SSH_USER, CP_IPS, WORKER_IPS, GPU_IPS, VIP, POD_CIDR, INSTALL_* 채우기

bash bastion/run.sh
```


`cluster.env`에 IP만 입력하면 다음 순서로 전체 설치가 진행됩니다:

1. 전체 노드: SSH 접근 부트스트랩 (비밀번호 인증 1회 → 키+NOPASSWD sudo로 전환)
2. 전체 노드: OS 초기 설정 → containerd → kubeadm 패키지 설치
3. Control Plane이 2대 이상이면: keepalived/haproxy로 VIP 구성
4. 첫 번째 CP에서 `kubeadm init` + Calico 설치, 나머지 노드는 `kubeadm join`
5. 전체 노드 Ready 확인
6. (옵션) GPU 노드에 NVIDIA 드라이버 설치 → GPU Operator → Kubeflow → MLflow 순서로 설치
7. 부트스트랩용 SSH 키/NOPASSWD 흔적 정리

CP 노드의 IP를 `WORKER_IPS`에도 같이 적으면 그 노드는 Control Plane과 Worker를 겸용으로 사용합니다 (taint 자동 제거).

## 제거

```bash
bash bastion/uninstall.sh mlflow         # MLflow만
bash bastion/uninstall.sh kubeflow       # Kubeflow (MLflow가 먼저 제거되어 있어야 함)
bash bastion/uninstall.sh gpu-operator   # GPU Operator만
bash bastion/uninstall.sh nvidia-driver  # 호스트 NVIDIA 드라이버 (GPU Operator가 먼저 제거되어 있어야 함)
bash bastion/uninstall.sh k8s            # 클러스터 전체 초기화 (되돌릴 수 없음)
bash bastion/uninstall.sh all            # 위 전부를 역순으로
```

## 설계 메모

- **아키텍처**: kubeadm + keepalived/haproxy 기반 HA. 별도 오케스트레이션 툴(Ansible 등) 없이 순수 bash + SSH로 구성됩니다.
- **아티팩트 스토어**: Kubeflow Pipelines 설치 시 함께 배포되는 SeaweedFS를 MLflow와 공유합니다. S3 호환 API와 접근키(`mlpipeline-minio-artifact` 시크릿)를 그대로 재사용하므로 별도 스토리지를 추가로 두지 않습니다. `mlflow`, `datasets` 버킷을 기본으로 생성합니다.
- **MLflow 통합**: 전용 네임스페이스(`mlflow`)로 Kubeflow와 수명주기를 분리하고, Istio Gateway에 `/mlflow` 경로로 연결하며 Kubeflow 대시보드 사이드바에 링크를 추가합니다.
- **GPU**: NVIDIA 드라이버는 GPU 노드에 직접 설치해 호스트에서 `nvidia-smi`가 바로 동작하도록 하고, 컨테이너 툴킷/디바이스 플러그인/NFD/DCGM은 GPU Operator(`driver.enabled=false`)가 관리합니다. GPU가 없는 노드에는 NFD가 자동으로 감지해 GPU 관련 컴포넌트를 배포하지 않으므로 CP나 CPU 전용 워커에 영향이 없습니다. MIG Manager는 설치는 해두되 어떤 GPU에도 MIG 설정을 적용하지 않아 GPU가 통째로 사용됩니다 (나중에 필요해지면 라벨 하나로 전환 가능).
- **보안**: bastion은 이 파이프라인 전용 임시 SSH 키를 생성해 노드에 배포하고, 설치가 끝나면 각 노드의 NOPASSWD sudo 설정과 해당 키의 `authorized_keys` 항목을 자동으로 제거합니다.

## 한계

- Kubeflow는 공식 uninstall 절차가 없어 `uninstall/20_kubeflow.sh`는 네임스페이스/CRD를 통째로 지우는 방식으로 동작합니다. 완전히 깨끗한 상태가 필요하면 `uninstall/00_k8s_reset.sh`로 클러스터 자체를 재설치하는 편이 확실합니다.
- 현재 모든 스크립트는 인터넷이 연결된 환경을 전제로 합니다 (apt/pip/GitHub/Docker Hub 등 공개 저장소 직접 접근). 폐쇄망/사내 레지스트리 연동은 아직 지원하지 않습니다.
