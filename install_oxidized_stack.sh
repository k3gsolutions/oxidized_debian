#!/usr/bin/env bash
set -euo pipefail

# ================================
# Variáveis de configuração
# ================================
OXIDIZED_CONFIG_PATH="/etc/oxidized"
OXIDIZED_DATA_PATH="${OXIDIZED_CONFIG_PATH}/.oxidized"
PORTAINER_VOLUME="portainer_data"
DOCKER_GPG_KEY="/etc/apt/keyrings/docker.asc"
DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.list"

# ================================
# Funções utilitárias
# ================================
log() { printf '%s\n' "[$(date '+%H:%M:%S')] $*"; }

fail() {
  log "ERRO: $*"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || fail "Este script precisa rodar como root."
}

require_debian() {
  if ! grep -qi 'debian' /etc/os-release; then
    fail "Distribuição não suportada. Use Debian 12/13."
  fi
}

wait_for_apt() {
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    log "APT em uso, aguardando..."
    sleep 2
  done
}

run_curl() {
  local url=$1
  curl -fsSL "$url"
}

wait_for_http() {
  local name=$1 url=$2 timeout=${3:-60} interval=${4:-3}
  local elapsed=0
  until curl -kfsS -o /dev/null "$url"; do
    if (( elapsed >= timeout )); then
      fail "${name} não respondeu em ${timeout}s (URL: ${url})."
    fi
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done
}

ensure_package() {
  local pkg=$1
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    wait_for_apt
    apt install -y "$pkg"
  fi
}

remove_container() {
  local name=$1
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
    docker rm -f "$name" >/dev/null
  fi
}

# ================================
# Passos de instalação
# ================================
install_docker() {
  log "Instalando Docker Engine..."
  wait_for_apt
  apt update -y
  apt install -y ca-certificates curl gnupg lsb-release apt-transport-https

  install -d -m 0755 /etc/apt/keyrings
  run_curl https://download.docker.com/linux/debian/gpg | gpg --dearmor -o "$DOCKER_GPG_KEY"
  chmod a+r "$DOCKER_GPG_KEY"

  cat <<EOF_REPO > "$DOCKER_REPO_FILE"
deb [arch=$(dpkg --print-architecture) signed-by=$DOCKER_GPG_KEY] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF_REPO

  wait_for_apt
  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log "Docker: $(docker --version)"
}

install_portainer() {
  log "Instalando Portainer..."
  docker volume create "$PORTAINER_VOLUME" >/dev/null
  remove_container portainer
  docker run -d \
    --name portainer \
    --restart=always \
    -p 8000:8000 \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v ${PORTAINER_VOLUME}:/data \
    portainer/portainer-ce:latest >/dev/null
  wait_for_http "Portainer" "https://localhost:9443" 120 5 || log "Aviso: Portainer ainda não respondeu, tente novamente em instantes."
}

configure_oxidized_files() {
  log "Preparando arquivos do Oxidized..."
  install -d -m 0755 "$OXIDIZED_CONFIG_PATH"
  install -d -m 0755 "$OXIDIZED_DATA_PATH"
  install -d -m 0755 "$OXIDIZED_CONFIG_PATH/configs"
  install -d -m 0755 "$OXIDIZED_CONFIG_PATH/logs"
  install -d -m 0755 "$OXIDIZED_CONFIG_PATH/crash"

  cat <<'CONFIG' > "$OXIDIZED_CONFIG_PATH/config"
---
pid: /tmp/oxidized.pid
interval: 3600
use_syslog: false
debug: false
threads: 30
timeout: 20
retries: 3

rest: 0.0.0.0:8888

input:
  default: ssh
  ssh:
    secure: false
    auth_methods:
      - password
      - publickey

output:
  default: file
  file:
    directory: "/home/oxidized/.oxidized/configs"

source:
  default: csv
  csv:
    file: "/home/oxidized/.config/oxidized/router.db"
    delimiter: !ruby/regexp /:/
    map:
      name: 0
      ip: 1
      model: 2
      input: 3
      username: 4
      password: 5
    vars_map:
      ssh_port: 6
CONFIG

  cat <<'ROUTER' > "$OXIDIZED_CONFIG_PATH/router.db"
# nome:ip:modelo:input:usuario:senha:porta
# Exemplo: core1:192.0.2.10:ios:ssh:admin:P@ssw0rd!:22
example-device:192.0.2.10:ios:ssh:admin:changeme:22
ROUTER

  chmod 640 "$OXIDIZED_CONFIG_PATH/config" "$OXIDIZED_CONFIG_PATH/router.db"
}

install_oxidized() {
  log "Instalando container Oxidized..."
  remove_container oxidized
  docker run -d \
    --name oxidized \
    --restart=always \
    --pull=always \
    -p 8888:8888 \
    -v ${OXIDIZED_CONFIG_PATH}:/home/oxidized/.config/oxidized \
    -v ${OXIDIZED_DATA_PATH}:/home/oxidized/.oxidized \
    oxidized/oxidized:latest >/dev/null

  wait_for_http "Oxidized" "http://localhost:8888/nodes" 180 5 || log "Aviso: Oxidized ainda inicializando."
}

run_validations() {
  log "Executando testes..."
  docker run --rm hello-world >/dev/null && log "Docker OK (hello-world)."

  if curl -sk https://localhost:9443 >/dev/null; then
    log "Portainer responde em https://$(hostname -I | awk '{print $1}'):9443"
  else
    log "Aviso: Portainer ainda não respondeu via HTTPS."
  fi

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8888/nodes || true)
  if [[ $code == "200" ]]; then
    log "Oxidized Web OK em http://$(hostname -I | awk '{print $1}'):8888"
  else
    log "Aviso: Oxidized retornou HTTP ${code}. Verifique docker logs oxidized."
  fi
}

show_summary() {
  log "Resumo final"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'NAMES|portainer|oxidized'
  log "Edite ${OXIDIZED_CONFIG_PATH}/router.db com seus dispositivos e rode 'docker restart oxidized' ou 'curl -s http://localhost:8888/nodes/reload' para recarregar."
}

main() {
  require_root
  require_debian
  install_docker
  install_portainer
  configure_oxidized_files
  install_oxidized
  run_validations
  show_summary
}

main "$@"
