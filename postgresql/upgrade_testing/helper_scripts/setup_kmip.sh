#!/bin/bash

set -e

start_kmip_server() {
  # Kill and existing kmip server
  if pgrep -f kmip >/dev/null; then
    sudo pkill -9 kmip || true
  fi

  # Determine docker command
  if docker ps >/dev/null 2>&1; then
      DOCKER="docker"
  elif sudo -n docker ps >/dev/null 2>&1; then
      DOCKER="sudo docker"
  else
      echo "[FAIL] Docker requires passwordless sudo or user must be in docker group"
      exit 1
  fi

  while $DOCKER ps -aq -f name=^kmip$ | grep -q .; do
    $DOCKER rm -f kmip > /dev/null 2>&1 || true
    sleep 1
  done

  # Start KMIP server
  $DOCKER run -d --security-opt seccomp=unconfined --cap-add=NET_ADMIN --rm -p 5696:5696 --name kmip mohitpercona/kmip:latest
  if [ -d /tmp/certs ]; then
      echo "Certs Directory Exists.."
      rm -rf /tmp/certs
      mkdir /tmp/certs
  else
      echo "Creating Certs Directory"
      mkdir /tmp/certs
  fi
  $DOCKER cp kmip:/opt/certs/root_certificate.pem /tmp/certs/
  $DOCKER cp kmip:/opt/certs/client_key_jane_doe.pem /tmp/certs/
  $DOCKER cp kmip:/opt/certs/client_certificate_jane_doe.pem /tmp/certs/

  kmip_server_address="0.0.0.0"
  kmip_server_port=5696
  kmip_client_ca="/tmp/certs/client_certificate_jane_doe.pem"
  kmip_client_key="/tmp/certs/client_key_jane_doe.pem"
  kmip_server_ca="/tmp/certs/root_certificate.pem"

  # Wait for KMIP server to be ready
  echo "Waiting for KMIP server to be ready..."

  for i in {1..60}; do
      if $DOCKER exec kmip sh -c "nc -z localhost 5696" >/dev/null 2>&1; then
          echo "KMIP server is ready"
          break
      fi
      sleep 1
  done

  # fail if not ready
  if ! $DOCKER exec kmip sh -c "nc -z localhost 5696" >/dev/null 2>&1; then
      echo "[FAIL] KMIP server did not become ready"
      exit 1
  fi
}
