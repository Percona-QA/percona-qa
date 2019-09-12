#!/usr/bin/env bats

@test "check ps" {
  run ./get_download_link.sh --product ps --version 5.5
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product ps --version 5.6
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product ps --version 5.7
  [ "$status" -eq 0 ]
}

@test "check pxc" {
  run ./get_download_link.sh --product pxc --version 5.5
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product pxc --version 5.6
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product pxc --version 5.7
  [ "$status" -eq 0 ]
}

@test "check psmdb" {
  run ./get_download_link.sh --product psmdb --version 3.0
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product psmdb --version 3.2
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product psmdb --version 3.4
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product psmdb --version 3.6
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product psmdb --version 4.0
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product psmdb --version 4.2
  [ "$status" -eq 0 ]
}

@test "check pt" {
  run ./get_download_link.sh --product pt
  [ "$status" -eq 0 ]
}
@test "check pxb" {
  run ./get_download_link.sh --product pxb
  [ "$status" -eq 0 ]
}


@test "check pmm-client" {
  run ./get_download_link.sh --product pmm-client
  [ "$status" -eq 0 ]
}

@test "check mysql" {
  run ./get_download_link.sh --product mysql --version 5.5
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mysql --version 5.6
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mysql --version 5.7
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mysql --version 8.0
  [ "$status" -eq 0 ]
}

@test "check mariadb" {
  run ./get_download_link.sh --product mariadb --version 10.0
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mariadb --version 10.1
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mariadb --version 10.2
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mariadb --version 10.3
  [ "$status" -eq 0 ]
}

@test "check mongodb" {
  run ./get_download_link.sh --product mongodb --version 3.2
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mongodb --version 3.4
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mongodb --version 3.6
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mongodb --version 4.0
  [ "$status" -eq 0 ]

  run ./get_download_link.sh --product mongodb --version 4.2
  [ "$status" -eq 0 ]
}

@test "check proxysql" {
  run ./get_download_link.sh --product proxysql
  [ "$status" -eq 0 ]
}

@test "check vault" {
  run ./get_download_link.sh --product vault
  [ "$status" -eq 0 ]
}

@test "check postgresql" {
  run ./get_download_link.sh --product postgresql
  [ "$status" -eq 0 ]
}
