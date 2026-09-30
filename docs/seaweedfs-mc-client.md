# SeaweedFS S3 접근 — `mc` CLI

Kubeflow 26.03부터 아티팩트 스토어가 MinIO에서 SeaweedFS로 바뀌면서, 예전처럼
MinIO 내장 Browser로 드래그앤드롭 업로드를 할 수 없다(`20_kubeflow.sh` 참고 —
브라우저 콘솔 없이 S3 API만 하위호환으로 제공됨). 수백 MB~수백 GB 규모의 파일을
다룰 때는 애초에 브라우저 업로드보다 S3 호환 CLI가 맞는 방법이므로, 여기서는
`mc`(MinIO Client — 이름과 무관하게 아무 S3 호환 서버에 붙는다)로 SeaweedFS에
접근하는 법을 정리한다.

## 1. `mc` 설치

```bash
curl https://dl.min.io/client/mc/release/linux-amd64/mc -o mc
chmod +x mc
sudo mv mc /usr/local/bin/mc
mc --version
```

## 2. 접근키 확인

모든 프로젝트가 `mlpipeline-minio-artifact` Secret을 공유한다(MinIO 시절과 동일한
이름/키로 하위호환 유지됨, `install/20_kubeflow.sh` 참고).

```bash
kubectl get secret mlpipeline-minio-artifact -n kubeflow \
  -o jsonpath='{.data.accesskey}' | base64 -d; echo
kubectl get secret mlpipeline-minio-artifact -n kubeflow \
  -o jsonpath='{.data.secretkey}' | base64 -d; echo
```

## 3. 접속 주소

| 실행 위치 | 주소 |
| --- | --- |
| 클러스터 내부(Pod/Job/Notebook 터미널) | `http://seaweedfs.kubeflow.svc.cluster.local:9000` |
| 클러스터 밖(개인 워크스테이션 등) | `http://<노드IP>:<SEAWEEDFS_S3_NODEPORT>` |

외부 접속은 `install/21_kubeflow_nodeport.sh`를 먼저 실행해 NodePort를 열어둬야
한다(기본 포트 30900, `--seaweedfs-s3-nodeport=`로 변경 가능). 이 스크립트는
선택 사항이라 실행하지 않았다면 클러스터 내부 경로만 쓸 수 있다.

## 4. alias 설정

```bash
mc alias set seaweed http://<주소>:<포트> <ACCESS_KEY> <SECRET_KEY>
mc ls seaweed
```

## 5. 대용량 업로드/다운로드

```bash
# 미리보기(아무것도 쓰지 않음)
mc mirror --dry-run ./local-dataset-dir seaweed/<bucket>/<prefix>/

# 실제 업로드 — 재시도/재개를 mc가 알아서 처리한다
mc mirror ./local-dataset-dir seaweed/<bucket>/<prefix>/

# 확인
mc ls --recursive seaweed/<bucket>/<prefix>/
du -sh ./local-dataset-dir
```

`mc mirror`는 개별 object 전송 실패 시 재시도하고, 큰 파일은 자동으로 멀티파트
업로드하므로 5~800GB 규모에도 적합하다. 단, **버전이 다른 dataset은 기존 prefix를
덮어쓰지 말고 새 prefix(`v0.0.2` → `v0.0.3`처럼)로 올린다** — `mc mirror` 자체의
덮어쓰기 동작에 기대지 않고, 새 prefix 사용을 안전장치로 삼는다. 업로드 전
`mc ls seaweed/<bucket>/<prefix>/`로 그 prefix가 비어 있는지 먼저 확인한다.

## 6. 알려진 한계

- 모든 프로젝트가 같은 `mlpipeline-minio-artifact` accesskey를 공유한다. bucket별
  최소 권한 분리는 아직 하지 않았다(운영 단계 후속 과제).
- 위 표의 NodePort는 인증 없는 HTTP다. 내부망/방화벽 뒤에서만 열어둔다.
