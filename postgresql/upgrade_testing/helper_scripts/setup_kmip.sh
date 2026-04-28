#! /bin/bash

set -e

start_kmip_server() {
  # Kill and existing kmip server
  if pgrep -f kmip >/dev/null; then
    sudo pkill -9 kmip || true
  fi

  while docker ps -aq -f name=^kmip$ | grep -q .; do
    sudo docker rm -f kmip > /dev/null 2>&1 || true
    sleep 1
  done

  # Start KMIP server
  sudo docker run -d --security-opt seccomp=unconfined --cap-add=NET_ADMIN --rm -p 5696:5696 --name kmip mohitpercona/kmip:latest
  if [ -d /tmp/certs ]; then
      echo "Certs Directory Exists.."
      rm -rf /tmp/certs
      mkdir /tmp/certs
  else
      echo "Creating Certs Directory"
      mkdir /tmp/certs
  fi
  sudo docker cp kmip:/opt/certs/root_certificate.pem /tmp/certs/
  sudo docker cp kmip:/opt/certs/client_key_jane_doe.pem /tmp/certs/
  sudo docker cp kmip:/opt/certs/client_certificate_jane_doe.pem /tmp/certs/

  kmip_server_address="0.0.0.0"
  kmip_server_port=5696
  kmip_client_ca="/tmp/certs/client_certificate_jane_doe.pem"
  kmip_client_key="/tmp/certs/client_key_jane_doe.pem"
  kmip_server_ca="/tmp/certs/root_certificate.pem"

  # Sleep for 30 sec to fully initialize the KMIP server
  sleep 30
}
