#! /bin/bash

set -e

_kmip_docker() {
  if [ -n "${KMIP_DOCKER:-}" ]; then
    # shellcheck disable=SC2086
    ${KMIP_DOCKER} "$@"
    return $?
  fi
  if docker info >/dev/null 2>&1; then
    docker "$@"
    return $?
  fi
  sudo docker "$@"
}

start_kmip_server() {
  # Kill and existing kmip server
  if pgrep -f kmip >/dev/null; then
    sudo pkill -9 kmip || true
  fi

  if _kmip_docker ps -q -f name=^kmip$ --filter status=running 2>/dev/null | grep -q .; then
    echo "KMIP container 'kmip' already running — reusing"
  else
    while _kmip_docker ps -aq -f name=^kmip$ 2>/dev/null | grep -q .; do
      _kmip_docker rm -f kmip > /dev/null 2>&1 || true
      sleep 1
    done
    _kmip_docker run -d --security-opt seccomp=unconfined --cap-add=NET_ADMIN --rm -p 5696:5696 --name kmip mohitpercona/kmip:latest
    sleep 30
  fi

  if [ -d /tmp/certs ]; then
      echo "Certs Directory Exists.."
      rm -rf /tmp/certs
      mkdir /tmp/certs
  else
      echo "Creating Certs Directory"
      mkdir /tmp/certs
  fi
  _kmip_docker cp kmip:/opt/certs/root_certificate.pem /tmp/certs/
  _kmip_docker cp kmip:/opt/certs/client_key_jane_doe.pem /tmp/certs/
  _kmip_docker cp kmip:/opt/certs/client_certificate_jane_doe.pem /tmp/certs/

  kmip_server_address="0.0.0.0"
  kmip_server_port=5696
  kmip_client_ca="/tmp/certs/client_certificate_jane_doe.pem"
  kmip_client_key="/tmp/certs/client_key_jane_doe.pem"
  kmip_server_ca="/tmp/certs/root_certificate.pem"
}
