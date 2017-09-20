#!/bin/bash

# Created by Shahriyar Rzayev from Percona

# General script for extracting and preparing mysqldump command

BASEDIR=$1

function extract_user() {
  # Function to extract mysql user
  user_conn="$(cat $1/cl_noprompt  | awk {'print $3'})"
  echo ${user_conn}
}

function extract_socket() {
  # Function to extract mysql socket
  socket_conn="$(cat $1/cl_noprompt  | awk {'print $4'})"
  echo ${socket_conn}
}

USER_NAME=$(extract_user ${BASEDIR})
SOCK_NAME=$(extract_socket ${BASEDIR})

function generate_mysqldump_command() {
  # Function to generate mysqldump command
  backup_command="$1/bin/mysqldump ${USER_NAME} ${SOCK_NAME}"
  echo ${backup_command}
}
