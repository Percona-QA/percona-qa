#!/usr/bin/env bats

# Check file existence at generated link with wget in spider mode. Check that file length is not 'unspecified'.
function  check_file(){
  echo -e "generaled_link = ${output}"
  wget_output="$(wget --spider ${output} 2>&1)"
  echo -e "Check generated link correctness. The wget output 'Length' is 'unspecified'"
  [ "$(echo $wget_output | grep 'Length' | grep -c 'unspecified')" -eq 0 ]
}

@test "check ps 5.6" {
  run ./get_download_link.sh --product ps --version 5.6
  [ "$status" -eq 0 ]
  check_file
}
@test "check ps 5.7" {
  run ./get_download_link.sh --product ps --version 5.7
  [ "$status" -eq 0 ]
  check_file
}
@test "check ps 8.0" {
  run ./get_download_link.sh --product ps --version 8.0
  [ "$status" -eq 0 ]
  check_file
}
@test "check ps for centos" {
  run ./get_download_link.sh --product ps --distribution centos
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.17')" -eq 1 ]
  check_file
}
@test "check ps for ubuntu bionic" {
  run ./get_download_link.sh --product ps --distribution ubuntu-bionic
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.17')" -eq 1 ]
  check_file
}
@test "check ps for ubuntu jammy" {
  run ./get_download_link.sh --product ps --distribution ubuntu-jammy
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.35')" -eq 1 ]
  check_file
}
@test "check ps 5.6 source" {
  run ./get_download_link.sh --product ps --version 5.6 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check ps 5.7 source" {
  run ./get_download_link.sh --product ps --version 5.7 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check ps 8.0 source" {
  run ./get_download_link.sh --product ps --version 8.0 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check pxc 5.7" {
  run ./get_download_link.sh --product pxc --version 5.7
  [ "$status" -eq 0 ]
  check_file
}
@test "check pxc 8.0" {
  run ./get_download_link.sh --product pxc --version 8.0
  [ "$status" -eq 0 ]
  check_file
}
@test "check pxc 5.7 source" {
  run ./get_download_link.sh --product pxc --version 5.7 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check pxc 8.0 source" {
  run ./get_download_link.sh --product pxc --version 8.0 --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check psmdb 4.2" {
  run ./get_download_link.sh --product psmdb --version 4.2
  [ "$status" -eq 0 ]
  check_file
}
@test "check psmdb 4.4" {
  run ./get_download_link.sh --product psmdb --version 4.4
  [ "$status" -eq 0 ]
  check_file
}
@test "check psmdb 5.0" {
  run ./get_download_link.sh --product psmdb --version 5.0
  [ "$status" -eq 0 ]
  check_file
}
@test "check psmdb 6.0" {
  run ./get_download_link.sh --product psmdb --version 6.0
  [ "$status" -eq 0 ]
  check_file
}

@test "check psmdb 4.2 source" {
  run ./get_download_link.sh --product psmdb --version 4.2 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check psmdb 4.4 source" {
  run ./get_download_link.sh --product psmdb --version 4.4 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check psmdb 5.0 source" {
  run ./get_download_link.sh --product psmdb --version 5.0 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check psmdb 6.0 source" {
  run ./get_download_link.sh --product psmdb --version 6.0 --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check psmdb 6.0 for jammy" {
  run ./get_download_link.sh --product psmdb --version 6.0 --distribution jammy
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.35')" -eq 1 ]
  check_file
}

@test "check pt" {
  run ./get_download_link.sh --product pt
  [ "$status" -eq 0 ]
  check_file
}

@test "check pt source" {
  run ./get_download_link.sh --product pt --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check pxb 2.4" {
  run ./get_download_link.sh --product pxb --version 2.4
  [ "$status" -eq 0 ]
  check_file
}
@test "check pxb 8.0" {
  run ./get_download_link.sh --product pxb --version 8.0
  [ "$status" -eq 0 ]
  check_file
}

@test "check pxb 2.4 source" {
  run ./get_download_link.sh --product pxb --version 2.4 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check pxb 8.0 source" {
  run ./get_download_link.sh --product pxb --version 8.0 --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check pxb 2.4 for centos" {
  run ./get_download_link.sh --product pxb --version 2.4 --distribution centos
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.12')" -eq 1 ]
  check_file
}
@test "check pxb 8.0 for centos" {
  run ./get_download_link.sh --product pxb --version 8.0 --distribution centos
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.17')" -eq 1 ]
  check_file
}

@test "check pmm-client" {
  run ./get_download_link.sh --product pmm-client
  [ "$status" -eq 0 ]
  check_file
}

@test "check pmm-client source" {
  run ./get_download_link.sh --product pmm-client --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check mysql 5.5 fails" {
  run ./get_download_link.sh --product mysql --version 5.5
  [ "$status" -eq 1 ]
}
@test "check mysql 5.6 fails" {
  run ./get_download_link.sh --product mysql --version 5.6
  [ "$status" -eq 1 ]
}

@test "check mysql 5.7" {
  run ./get_download_link.sh --product mysql --version 5.7
  [ "$status" -eq 0 ]
  check_file
}
@test "check mysql 8.0" {
  run ./get_download_link.sh --product mysql --version 8.0
  [ "$status" -eq 0 ]
  check_file
}

@test "check mysql 5.7 source" {
  run ./get_download_link.sh --product mysql --version 5.7 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check mysql 8.0 source" {
  run ./get_download_link.sh --product mysql --version 8.0 --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check mariadb 10.2" {
  run ./get_download_link.sh --product mariadb --version 10.2
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.3" {
  run ./get_download_link.sh --product mariadb --version 10.3
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.4" {
  run ./get_download_link.sh --product mariadb --version 10.4
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.9" {
  run ./get_download_link.sh --product mariadb --version 10.9
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.10" {
  run ./get_download_link.sh --product mariadb --version 10.10
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.2 source" {
  run ./get_download_link.sh --product mariadb --version 10.2 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.3 source" {
  run ./get_download_link.sh --product mariadb --version 10.3 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.4 source" {
  run ./get_download_link.sh --product mariadb --version 10.4 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.9 source" {
  run ./get_download_link.sh --product mariadb --version 10.9 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check mariadb 10.10 source" {
  run ./get_download_link.sh --product mariadb --version 10.10 --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check mongodb 4.2" {
  ./get_download_link.sh --product mongodb --version 4.2 --distribution rhel70
  [ "$status" -eq 0 ]
  check_file
}
@test "check mongodb 4.4" {
  ./get_download_link.sh --product mongodb --version 4.4 --distribution debian10
  [ "$status" -eq 0 ]
  check_file
}
@test "check mongodb 5.0" {
  ./get_download_link.sh --product mongodb --version 5.0 --distribution ubuntu2004
  [ "$status" -eq 0 ]
  check_file
}
@test "check mongodb 6.0" {
  ./get_download_link.sh --product mongodb --version 6.0  --distribution amazon2
  [ "$status" -eq 0 ]
  check_file
}

@test "check mongodb 4.2 source" {
  ./get_download_link.sh --product mongodb --version 4.2 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check mongodb 4.4 source" {
  ./get_download_link.sh --product mongodb --version 4.4 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check mongodb 5.0 source" {
  ./get_download_link.sh --product mongodb --version 5.0 --source
  [ "$status" -eq 0 ]
  check_file
}
@test "check mongodb 6.0 source" {
  ./get_download_link.sh --product mongodb --version 6.0 --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check proxysql" {
  run ./get_download_link.sh --product proxysql
  [ "$status" -eq 0 ]
  check_file
}

@test "check proxysql source" {
  run ./get_download_link.sh --product proxysql --source
  [ "$status" -eq 0 ]
  check_file
}

@test "check vault" {
  run ./get_download_link.sh --product vault
  [ "$status" -eq 0 ]
  check_file
}

@test "check postgresql" {
  run ./get_download_link.sh --product postgresql
  [ "$status" -eq 0 ]
  check_file
}
