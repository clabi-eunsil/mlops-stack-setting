#!/usr/bin/env bash

# keepalived + haproxy 설치: k8s Control Plane HA용 VIP 구성
# CP가 2대 이상일 때만 필요 (CP 1대짜리 구성이면 이 스크립트 자체를 실행하지 않으면 됨)
#
# 사용법:
#   sudo bash 04_ha_setup.sh <THIS_NODE_IP> <VIP> <CP_IP_1> [<CP_IP_2> ...]
#   - CP_IP 목록은 모든 CP에서 동일한 순서로 넘겨야 함 (우선순위가 순서로 정해짐)
#   - THIS_NODE_IP는 CP_IP 목록에 반드시 포함되어야 함
#
# 예시 (CP 3대: 10.0.0.11, 10.0.0.12, 10.0.0.13, VIP 10.0.0.10):
#   각 CP에서 동일하게:
#   sudo bash 04_ha_setup.sh 10.0.0.11 10.0.0.10 10.0.0.11 10.0.0.12 10.0.0.13
#   sudo bash 04_ha_setup.sh 10.0.0.12 10.0.0.10 10.0.0.11 10.0.0.12 10.0.0.13
#   sudo bash 04_ha_setup.sh 10.0.0.13 10.0.0.10 10.0.0.11 10.0.0.12 10.0.0.13
#
# 설계 메모:
# - 모든 노드를 state=BACKUP으로 띄우고 priority(목록 내 순서)로만 우열을 가림
#   -> "누가 최초 MASTER인지"를 별도로 지정할 필요가 없어 노드 추가/재실행이 단순

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

require_root
setup_logging "04_ha_setup"

[[ $# -ge 3 ]] || die "사용법: sudo bash $0 <THIS_NODE_IP> <VIP> <CP_IP_1> [<CP_IP_2> ...]"

THIS_IP="$1"
VIP="$2"
shift 2
CP_IPS=("$@")

APISERVER_PORT="6443"
HAPROXY_PORT="6443"

# THIS_IP가 목록에서 몇 번째인지로 priority 결정 (앞쪽일수록 높음)
PRIORITY=0
FOUND=0
idx=0
for ip in "${CP_IPS[@]}"; do
  idx=$((idx + 1))
  if [[ "$ip" == "$THIS_IP" ]]; then
    PRIORITY=$((200 - idx))
    FOUND=1
  fi
done
[[ "$FOUND" -eq 1 ]] || die "THIS_NODE_IP(${THIS_IP})가 CP_IP 목록(${CP_IPS[*]})에 없습니다."

echo "========================================"
echo " THIS_IP : ${THIS_IP}"
echo " VIP     : ${VIP}"
echo " CP_IPS  : ${CP_IPS[*]}"
echo " PRIORITY: ${PRIORITY}"
echo "========================================"

yellow "==[1/4] keepalived + haproxy 설치 =="
apt-get update
apt-get install -y keepalived haproxy
green "설치 완료"

yellow "==[2/4] haproxy 설정 =="
NIC=$(ip -o link show | awk -F': ' '!/lo/{print $2}' | head -1)
echo "감지된 NIC: ${NIC}"

{
  cat <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms

frontend k8s-apiserver
    bind *:${HAPROXY_PORT}
    mode tcp
    default_backend k8s-apiservers

backend k8s-apiservers
    mode tcp
    balance roundrobin
    option tcp-check
EOF
  idx=0
  for ip in "${CP_IPS[@]}"; do
    idx=$((idx + 1))
    echo "    server cp-${idx} ${ip}:${APISERVER_PORT} check fall 3 rise 2"
  done
  cat <<EOF

listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
EOF
} > /etc/haproxy/haproxy.cfg

haproxy -c -f /etc/haproxy/haproxy.cfg && green "haproxy 설정 검증 완료" || die "haproxy 설정 오류"

yellow "==[3/4] keepalived 설정 =="
cat > /etc/keepalived/check_apiserver.sh <<EOF
#!/bin/bash
errorExit() {
  echo "*** \$*" 1>&2
  exit 1
}
curl -sfk --max-time 2 https://localhost:${APISERVER_PORT}/healthz -o /dev/null || errorExit "apiserver not responding"
EOF
chmod +x /etc/keepalived/check_apiserver.sh

cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
  router_id LVS_DEVEL
  script_user root
  enable_script_security
}

vrrp_script check_apiserver {
  script "/etc/keepalived/check_apiserver.sh"
  interval 3
  weight -2
  fall 10
  rise 2
}

vrrp_instance VI_1 {
  state BACKUP
  interface ${NIC}
  virtual_router_id 51
  priority ${PRIORITY}
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass k8shapass
  }

  virtual_ipaddress {
    ${VIP}
  }

  track_script {
    check_apiserver
  }
}
EOF
green "keepalived 설정 완료 (priority: ${PRIORITY})"

yellow "==[4/4] 서비스 시작 및 확인 =="
systemctl enable --now haproxy
systemctl enable --now keepalived
sleep 3

systemctl is-active haproxy    && green "haproxy: OK"    || red "haproxy: FAIL"
systemctl is-active keepalived && green "keepalived: OK" || red "keepalived: FAIL"

echo
echo "---- VIP 확인 (priority가 가장 높은 노드에서만 보여야 함) ----"
ip a show "${NIC}" | grep "${VIP}" && green "VIP ${VIP} 활성화됨 (이 노드가 현재 MASTER)" || yellow "VIP 없음 (BACKUP이면 정상)"

echo "haproxy stats: http://${THIS_IP}:8404/stats"
echo "Log: ${LOG_DIR}/04_ha_setup.log"
green "DONE: HA 설정 완료"
