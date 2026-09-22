#!/usr/bin/env bash

# install/*.sh, uninstall/*.sh 공통 함수
# 사용법: 각 스크립트 맨 위에서
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../common/lib.sh"

green()  { echo -e "\033[1;32m$1\033[0m"; }
yellow() { echo -e "\033[1;33m$1\033[0m"; }
red()    { echo -e "\033[1;31m$1\033[0m"; }

die()  { red "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "root 권한으로 실행하세요 (sudo -i 후 실행, 또는 sudo bash $0)"
}

# 로그를 /tmp/setup-log/<이름>.log 에 남기고 화면에도 출력
# 사용법: setup_logging "01_k8s_prereq"
setup_logging() {
  local name="$1"
  LOG_DIR="/tmp/setup-log"
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "${LOG_DIR}/${name}.log") 2>&1
}
