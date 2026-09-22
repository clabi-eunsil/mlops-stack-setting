#!/usr/bin/env bash

# bastion/run.sh 전용: 깡통 서버(SSH 키 없음, 비밀번호 인증만 가능)를
# 키 기반 + NOPASSWD sudo 상태로 부트스트랩한 뒤, 이후 무인으로 원격 실행
#
# 사용 흐름:
#   1) ensure_local_key                 : bastion(이 스크립트를 실행하는 노드)에 부트스트랩 전용 키가 없으면 생성
#   2) bootstrap_node <user> <ip>       : 최초 1회, 비밀번호 프롬프트가 뜸 (ssh-copy-id, sudo -v)
#   3) remote_copy <user> <ip>          : install/, uninstall/, common/ 을 대상 노드로 복사
#   4) remote_run  <user> <ip> <script> : 복사된 스크립트를 sudo로 무인 실행
#                                          script는 "install/00_os_base.sh"처럼 REMOTE_DIR 기준 상대경로
#   5) cleanup_node <user> <ip>         : 파이프라인 끝나면 NOPASSWD sudo + 이 키를 대상 노드에서 제거
#
# 보안 주의:
# - SSH_KEY는 절대 평소 쓰는 개인 키(~/.ssh/id_ed25519 등)를 기본값으로 두지 않음.
#   이 키는 "설치 자동화 동안만" 전체 노드에 뿌려지는 임시 키이므로 탈취 시 피해 범위를 최소화하려면
#   이 파이프라인 전용으로 새로 만들고, 끝나면 cleanup_node로 각 노드에서 흔적을 지운다.
# - cleanup_node는 NOPASSWD sudoers 드롭인과 authorized_keys의 공개키 항목을 함께 제거한다.
#   (sudo만 지우면 키 탈취 시 로그인은 여전히 되고, 키만 지우면 NOPASSWD가 남아 다른 경로로 침투 시 위험이 남음)
#
# SSH 키가 이미 배포되어 있다고 가정하지 않고, 비밀번호 인증만 되는 최초 상태부터
# 부트스트랩 -> 정리까지 전부 이 안에서 처리함

SSH_KEY="${SSH_KEY:-$HOME/.ssh/mlops_bootstrap_ed25519}"
REMOTE_DIR="${REMOTE_DIR:-~/mlops-bootstrap}"
SSH_PORT="${SSH_PORT:-22}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

ensure_local_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    yellow "부트스트랩 전용 키가 없어 새로 생성합니다: ${SSH_KEY}"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -q -C "mlops-bootstrap-temporary"
  fi
}

ssh_key_works() {
  local user="$1" ip="$2"
  ssh -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes "${SSH_OPTS[@]}" "${user}@${ip}" "true" >/dev/null 2>&1
}

sudo_works() {
  local user="$1" ip="$2"
  ssh -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes "${SSH_OPTS[@]}" "${user}@${ip}" "sudo -n true" >/dev/null 2>&1
}

# 최초 1회: 비밀번호 인증으로 키를 배포하고, NOPASSWD sudo를 심어둠
# 이미 키/NOPASSWD가 되어 있으면 아무것도 묻지 않고 통과 (재실행 안전)
bootstrap_node() {
  local user="$1" ip="$2"

  if ssh_key_works "$user" "$ip"; then
    green "[$ip] SSH 키 접속 OK"
  else
    yellow "[$ip] SSH 키가 아직 없습니다. 비밀번호를 입력해 키를 배포합니다."
    ssh-copy-id -i "${SSH_KEY}.pub" -p "$SSH_PORT" "${SSH_OPTS[@]}" "${user}@${ip}" \
      || die "[$ip] ssh-copy-id 실패. 계정/비밀번호/네트워크를 확인하세요."
    ssh_key_works "$user" "$ip" || die "[$ip] 키 배포 후에도 접속 실패."
    green "[$ip] SSH 키 배포 완료"
  fi

  if sudo_works "$user" "$ip"; then
    green "[$ip] NOPASSWD sudo OK"
  else
    yellow "[$ip] sudo 비밀번호가 필요합니다. 1회만 입력하면 이후 자동화됩니다."
    # -t: pty 할당 -> sudo가 비밀번호를 대화형으로 물어볼 수 있게 함
    ssh -t -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "${user}@${ip}" "
      sudo -v || exit 1
      echo '${user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-bootstrap-nopasswd >/dev/null
      sudo chmod 440 /etc/sudoers.d/90-bootstrap-nopasswd
    " || die "[$ip] sudo 부트스트랩 실패."
    sudo_works "$user" "$ip" || die "[$ip] NOPASSWD 설정 후에도 sudo -n 실패."
    green "[$ip] NOPASSWD sudo 설정 완료"
  fi
}

remote_copy() {
  local user="$1" ip="$2" repo_root="$3"
  ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "${user}@${ip}" "mkdir -p ${REMOTE_DIR}"
  # scp는 포트 옵션이 -p가 아니라 -P (소문자 -p는 "타임스탬프 보존" 옵션이라 충돌함)
  scp -i "$SSH_KEY" -P "$SSH_PORT" -q -r "${repo_root}/common" "${repo_root}/install" "${repo_root}/uninstall" \
    "${user}@${ip}:${REMOTE_DIR}/"
}

# script는 REMOTE_DIR 기준 상대경로를 그대로 전달 (예: "install/00_os_base.sh", "uninstall/30_mlflow.sh")
# 나머지 인자는 그 스크립트에 그대로 전달되는 위치 인자
# (04_ha_setup.sh의 VIP/CP_IP 목록, 05_kubeadm_bootstrap.sh의 join 명령 문자열 등)
# join 명령처럼 공백이 섞인 문자열도 안전하게 넘기기 위해 printf %q로 개별 인용
remote_run() {
  local user="$1" ip="$2" script="$3"
  shift 3
  local quoted=""
  local a
  for a in "$@"; do
    quoted+=" $(printf '%q' "$a")"
  done
  ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "${user}@${ip}" \
    "sudo bash ${REMOTE_DIR}/${script}${quoted}"
}

# CP1에서 kubeadm-join-*.sh 내용을 읽어와 다른 노드에 그대로 전달하기 위함
fetch_remote_file() {
  local user="$1" ip="$2" path="$3"
  ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "${user}@${ip}" "sudo cat ${path}"
}

# CP1을 통해 전체 노드가 Ready 상태가 될 때까지 대기 (GPU Operator/Kubeflow 설치 전 게이트)
wait_for_nodes_ready() {
  local user="$1" ip="$2" expected="$3" timeout="${4:-300}"
  local waited=0 ready
  while true; do
    ready="$(ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "${user}@${ip}" \
      "sudo kubectl get nodes --no-headers 2>/dev/null | awk '\$2==\"Ready\"' | wc -l" 2>/dev/null || echo 0)"
    [[ "$ready" -ge "$expected" ]] && return 0
    waited=$((waited + 10))
    [[ "$waited" -ge "$timeout" ]] && return 1
    sleep 10
  done
}

# 해당 노드의 파이프라인이 전부 끝난 뒤 호출: NOPASSWD sudo와 이 부트스트랩 키의
# authorized_keys 항목을 함께 제거해 "키 탈취 = 전체 서버 장악" 위험을 없앤다.
# sudo 권한이 아직 살아있는 이 세션 안에서 sudoers 파일부터 지우고, 마지막에 키 항목을 지운다
# (키 항목을 먼저 지워도 이미 맺힌 현재 세션엔 영향 없음 — 다음 접속부터 막히는 것)
cleanup_node() {
  local user="$1" ip="$2"
  local pubkey
  pubkey="$(cat "${SSH_KEY}.pub")"

  yellow "[$ip] 부트스트랩 흔적 정리 (NOPASSWD sudo + bastion 임시 키 제거)"
  ssh -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_OPTS[@]}" "${user}@${ip}" "
    sudo rm -f /etc/sudoers.d/90-bootstrap-nopasswd
    if [[ -f ~/.ssh/authorized_keys ]]; then
      grep -vF '${pubkey}' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp || true
      mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys
    fi
  " || yellow "[$ip] WARNING: 정리 중 일부 실패 - 수동으로 /etc/sudoers.d/90-bootstrap-nopasswd 와 authorized_keys 확인 필요"
}
