#!/usr/bin/env bats

@test "check ps 5.6" {
  ./get_download_link.sh --product ps --version 5.6
}
@test "check ps 5.7" {
  ./get_download_link.sh --product ps --version 5.7
}
@test "check ps 8.0" {
  ./get_download_link.sh --product ps --version 8.0
}

@test "check ps for centos" {
  run ./get_download_link.sh --product ps --distribution centos
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.17')" -eq 1 ]
}
@test "check ps for ubuntu bionic" {
  run ./get_download_link.sh --product ps --distribution ubuntu-bionic
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.17')" -eq 1 ]
}
@test "check ps for ubuntu jammy" {
  run ./get_download_link.sh --product ps --distribution ubuntu-jammy
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.35')" -eq 1 ]
}

@test "check ps 5.6 source" {
  ./get_download_link.sh --product ps --version 5.6 --source
}
@test "check ps 5.7 source" {
  ./get_download_link.sh --product ps --version 5.7 --source
}
@test "check ps 8.0 source" {
  ./get_download_link.sh --product ps --version 8.0 --source
}

@test "check pxc 5.7" {
  ./get_download_link.sh --product pxc --version 5.7
}
@test "check pxc 8.0" {
  ./get_download_link.sh --product pxc --version 8.0
}

@test "check pxc 5.7 source" {
  ./get_download_link.sh --product pxc --version 5.7 --source
}
@test "check pxc 8.0 source" {
  ./get_download_link.sh --product pxc --version 8.0 --source
}


@test "check psmdb 3.4" {
  ./get_download_link.sh --product psmdb --version 3.4
}
@test "check psmdb 3.6" {
  ./get_download_link.sh --product psmdb --version 3.6
}
@test "check psmdb 4.0" {
  ./get_download_link.sh --product psmdb --version 4.0
}
@test "check psmdb 4.2" {
  ./get_download_link.sh --product psmdb --version 4.2
}

@test "check psmdb 3.4 source" {
  ./get_download_link.sh --product psmdb --version 3.4 --source
}
@test "check psmdb 3.6 source" {
  ./get_download_link.sh --product psmdb --version 3.6 --source
}
@test "check psmdb 4.0 source" {
  ./get_download_link.sh --product psmdb --version 4.0 --source
}
@test "check psmdb 4.2 source" {
  ./get_download_link.sh --product psmdb --version 4.2 --source
}

@test "check psmdb 3.4 for centos" {
  run ./get_download_link.sh --product psmdb --version 3.4 --distribution centos
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'centos6')" -eq 1 ]
}

@test "check pt" {
  ./get_download_link.sh --product pt
}

@test "check pt source" {
  ./get_download_link.sh --product pt --source
}

@test "check pxb 2.4" {
  ./get_download_link.sh --product pxb --version 2.4
}
@test "check pxb 8.0" {
  ./get_download_link.sh --product pxb --version 8.0
}

@test "check pxb 2.4 source" {
  ./get_download_link.sh --product pxb --version 2.4 --source
}
@test "check pxb 8.0 source" {
  ./get_download_link.sh --product pxb --version 8.0 --source
}

@test "check pxb 2.4 for centos" {
  run ./get_download_link.sh --product pxb --version 2.4 --distribution centos
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'libgcrypt145')" -eq 1 ]
}
@test "check pxb 8.0 for centos" {
  run ./get_download_link.sh --product pxb --version 8.0 --distribution centos
  [ "$status" -eq 0 ]
  [ "$(echo $output | grep -c 'glibc2.12')" -eq 1 ]
}

@test "check pmm-client" {
  ./get_download_link.sh --product pmm-client
}

@test "check pmm-client source" {
  ./get_download_link.sh --product pmm-client --source
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
  ./get_download_link.sh --product mysql --version 5.7
}
@test "check mysql 8.0" {
  ./get_download_link.sh --product mysql --version 8.0
}

@test "check mysql 5.7 source" {
  ./get_download_link.sh --product mysql --version 5.7 --source
}
@test "check mysql 8.0 source" {
  ./get_download_link.sh --product mysql --version 8.0 --source
}

@test "check mariadb 10.2" {
  ./get_download_link.sh --product mariadb --version 10.2
}
@test "check mariadb 10.3" {
  ./get_download_link.sh --product mariadb --version 10.3
}
@test "check mariadb 10.4" {
  ./get_download_link.sh --product mariadb --version 10.4
}

@test "check mariadb 10.2 source" {
  ./get_download_link.sh --product mariadb --version 10.2 --source
}
@test "check mariadb 10.3 source" {
  ./get_download_link.sh --product mariadb --version 10.3 --source
}
@test "check mariadb 10.4 source" {
  ./get_download_link.sh --product mariadb --version 10.4 --source
}

@test "check mongodb 3.4" {
  ./get_download_link.sh --product mongodb --version 3.4
}
@test "check mongodb 3.6" {
  ./get_download_link.sh --product mongodb --version 3.6
}
@test "check mongodb 4.0" {
  ./get_download_link.sh --product mongodb --version 4.0
}
@test "check mongodb 4.2" {
  ./get_download_link.sh --product mongodb --version 4.2
}

@test "check proxysql" {
  ./get_download_link.sh --product proxysql
}

@test "check proxysql source" {
  ./get_download_link.sh --product proxysql --source
}

@test "check vault" {
  ./get_download_link.sh --product vault
}

@test "check postgresql" {
  ./get_download_link.sh --product postgresql
}
