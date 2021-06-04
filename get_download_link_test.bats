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

@test "check pxc 5.5" {
  ./get_download_link.sh --product pxc --version 5.5
}
@test "check pxc 5.6" {
  ./get_download_link.sh --product pxc --version 5.6
}
@test "check pxc 5.7" {
  ./get_download_link.sh --product pxc --version 5.7
}
@test "check pxc 8.0" {
  ./get_download_link.sh --product pxc --version 8.0
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

@test "check pt" {
  ./get_download_link.sh --product pt
}

@test "check pxb 2.4" {
  ./get_download_link.sh --product pxb --version 2.4
}
@test "check pxb 8.0" {
  ./get_download_link.sh --product pxb --version 8.0
}

@test "check pmm-client" {
  ./get_download_link.sh --product pmm-client
}

@test "check mysql 5.5" {
  ./get_download_link.sh --product mysql --version 5.5
}
@test "check mysql 5.6" {
  ./get_download_link.sh --product mysql --version 5.6
}
@test "check mysql 5.7" {
  ./get_download_link.sh --product mysql --version 5.7
}
@test "check mysql 8.0" {
  ./get_download_link.sh --product mysql --version 8.0
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

@test "check vault" {
  ./get_download_link.sh --product vault
}

@test "check postgresql" {
  ./get_download_link.sh --product postgresql
}
