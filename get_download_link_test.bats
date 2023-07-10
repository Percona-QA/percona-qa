#!/usr/bin/env bats

function execute_test(){
  for arg
  do
    case "$arg" in
      -p | --product )
      local test_product="$2"
      shift 2
      ;;
      -v | --version )
      local version="$2"
      local test_version="--version ${version}"
      shift 2
      ;;
      -d | --distribution )
      local distribution="$2"
      local test_distribution="--distribution ${distribution}"
      shift 2
      ;;
      -g | --glibc )
      local glibc="$2"
      shift 2
      ;;
      -s | --source )
      local test_source="--source"
      ;;
    esac
  done
  # run get_download_link command
  echo "Executed query: run ./get_download_link.sh --product ${test_product} ${test_version} ${test_source} ${test_distribution}"
  run ./get_download_link.sh --product ${test_product} ${test_version} ${test_source} ${test_distribution}
  # check whether command was executed successfully
  [ "$status" -eq 0 ]
  # check file existence at generated link with wget in spider mode. Check that file length is not 'unspecified'.
  echo -e "generaled_link = ${output}"
  wget_output="$(wget --spider ${output} 2>&1)"
  echo -e "Check generated link correctness. The wget output 'Length' may be 'unspecified'"
  [ "$(echo $wget_output | grep 'Length' | grep -c 'unspecified')" -eq 0 ]
  # if the glibc and version was passed: check that version in the generated link is the same as the passed version.
  if [[ -n ${glibc} ]]; then
    echo -e "Check generated link glibc. The glibc in link is incorrect"
    [ "$(echo ${output} | egrep -c "${glibc}")" -eq 1 ]
  fi
  if [[ -n ${version} ]]; then
    echo -e "Check generated link version. The version in link is incorrect"
    [ "$(echo ${output} | egrep -c "${version}")" -eq 1 ]
  fi
}

@test "check ps 5.6" {
  execute_test --product ps --version 5.6
}
@test "check ps 5.6.49" {
  execute_test --product ps --version 5.6.49
}
@test "check ps 5.6.49-89" {
  execute_test --product ps --version 5.6.49-89
}
@test "check ps 5.6.49-89.0" {
  execute_test --product ps --version 5.6.49-89.0
}
@test "check ps 5.7" {
  execute_test --product ps --version 5.7
}
@test "check ps 5.7.37" {
  execute_test --product ps --version 5.7.37
}
@test "check ps 5.7.37-40" {
  execute_test --product ps --version 5.7.37-40
}
@test "check ps 8.0" {
  execute_test --product ps --version 8.0
}
@test "check ps 8.0.31" {
  execute_test --product ps --version 8.0.31
}
@test "check ps 8.0.31-23" {
  execute_test --product ps --version 8.0.31-23
}
@test "check ps for centos" {
  execute_test --product ps --distribution centos --glibc glibc2.17
}
@test "check ps for ubuntu bionic" {
  execute_test --product ps --distribution ubuntu-bionic --glibc glibc2.17
}
@test "check ps for ubuntu jammy" {
  execute_test --product ps --distribution ubuntu-jammy --glibc glibc2.35
}
@test "check ps 5.6 source" {
  execute_test --product ps --version 5.6 --source
}
@test "check ps 5.6.49 source" {
  execute_test --product ps --version 5.6.49 --source
}
@test "check ps 5.6.49-89 source" {
  execute_test --product ps --version 5.6.49-89 --source
}
@test "check ps 5.6.49-89.0 source" {
  execute_test --product ps --version 5.6.49-89.0 --source
}
@test "check ps 5.7 source" {
  execute_test --product ps --version 5.7 --source
}
@test "check ps 5.7.37 source" {
  execute_test --product ps --version 5.7.37 --source
}
@test "check ps 5.7.37-40" source {
  execute_test --product ps --version 5.7.37-40 --source
}
@test "check ps 8.0 source" {
  execute_test --product ps --version 8.0 --source
}
@test "check ps 8.0.31 source" {
  execute_test --product ps --version 8.0.31 --source
}
@test "check ps 8.0.31-23 source" {
  execute_test --product ps --version 8.0.31-23 --source
}

@test "check pxc 5.7" {
  execute_test --product pxc --version 5.7
}
@test "check pxc 5.7.37" {
  execute_test --product pxc --version 5.7.37
}
@test "check pxc 5.7.37-31" {
  execute_test --product pxc --version 5.7.37-31
}
@test "check pxc 5.7.37-31.57" {
  execute_test --product pxc --version 5.7.37-31.57
}
@test "check pxc 8.0" {
  execute_test --product pxc --version 8.0
}
@test "check pxc 8.0.21" {
  execute_test --product pxc --version 8.0.21
}
@test "check pxc 8.0.21-12" {
  execute_test --product pxc --version 8.0.21-12
}
@test "check pxc 8.0.31-23.1" {
  execute_test --product pxc --version 8.0.31-23.1
}
@test "check pxc 8.0.31-23.2" {
  execute_test --product pxc --version 8.0.31-23.2
}
@test "check pxc 5.7 source" {
  execute_test --product pxc --version 5.7 --source
}
@test "check pxc 5.7.37 source" {
  execute_test --product pxc --version 5.7.37 --source
}
@test "check pxc 5.7.37-31 source" {
  execute_test --product pxc --version 5.7.37-31 --source
}
@test "check pxc 5.7.37-31.57 source" {
  execute_test --product pxc --version 5.7.37-31.57
}
@test "check pxc 8.0 source" {
  execute_test --product pxc --version 8.0 --source
}
@test "check pxc 8.0.21 source" {
  execute_test --product pxc --version 8.0.21 --source
}
@test "check pxc 8.0.21-12 source" {
  execute_test --product pxc --version 8.0.21-12 --source
}

@test "check proxysql" {
  execute_test --product proxysql
}

@test "check psmdb 4.2" {
  execute_test --product psmdb --version 4.2
}
@test "check psmdb 4.4" {
  execute_test --product psmdb --version 4.4
}
@test "check psmdb 5.0" {
  execute_test --product psmdb --version 5.0
}
@test "check psmdb 6.0" {
  execute_test --product psmdb --version 6.0
}
@test "check psmdb 6.0.4" {
  execute_test --product psmdb --version 6.0.4
}
@test "check psmdb 6.0.4-3" {
  execute_test --product psmdb --version 6.0.4-3
}
@test "check psmdb 4.2 source" {
  execute_test --product psmdb --version 4.2 --source
}
@test "check psmdb 4.4 source" {
  execute_test --product psmdb --version 4.4 --source
}
@test "check psmdb 5.0 source" {
  execute_test --product psmdb --version 5.0 --source
}
@test "check psmdb 6.0 source" {
  execute_test --product psmdb --version 6.0 --source
}
@test "check psmdb 6.0 for jammy" {
  execute_test --product psmdb --version 6.0 --distribution jammy --glibc glibc2.35
}

@test "check pt" {
  execute_test --product pt
}
@test "check pt 3.5.1" {
  execute_test --product pt --version 3.5.1
}
@test "check pt source" {
  execute_test --product pt --source
}
@test "check pt 3.5.1 source" {
  execute_test --product pt --version 3.5.1 --source
}

@test "check pxb 2.4" {
  execute_test --product pxb --version 2.4
}
@test "check pxb 2.4.27" {
  execute_test --product pxb --version 2.4.27
}
@test "check pxb 8.0" {
  execute_test --product pxb --version 8.0
}
@test "check pxb 8.0.30" {
  execute_test --product pxb --version 8.0.30
}
@test "check pxb 8.0.30-23" {
  execute_test --product pxb --version 8.0.30-23
}
@test "check pxb 8.0.32" {
  execute_test --product pxb --version 8.0.32
}
@test "check pxb 8.0.32-25" {
  execute_test --product pxb --version 8.0.32-25
}
@test "check pxb 2.4 source" {
  execute_test --product pxb --version 2.4 --source
}
@test "check pxb 2.4.27 source" {
  execute_test --product pxb --version 2.4.27 --source
}
@test "check pxb 8.0 source" {
  execute_test --product pxb --version 8.0 --source
}
@test "check pxb 8.0.32 source" {
  execute_test --product pxb --version 8.0.32 --source
}
@test "check pxb8.0.32-25 source" {
  execute_test --product pxb --version 8.0.32-25 --source
}
@test "check pxb 8.0 for centos" {
  execute_test --product pxb --version 8.0 --distribution centos --glibc glibc2.17
}

@test "check pmm-client" {
  execute_test --product pmm-client
}
@test "check pmm-client 2.33" {
  execute_test --product pmm-client --version 2.33
}
@test "check pmm-client 2.34.0" {
  execute_test --product pmm-client --version 2.34.0
}
@test "check pmm-client source" {
  execute_test --product pmm-client --source
}
@test "check pmm-client 2.33 source" {
  execute_test --product pmm-client --version 2.33 --source
}
@test "check pmm-client 2.33 source" {
  execute_test --product pmm-client --version 2.34.0 --source
}

@test "check mysql 5.7" {
  execute_test --product mysql --version 5.7
}
@test "check mysql 8.0" {
  execute_test --product mysql --version 8.0
}
@test "check mysql 5.7 source" {
  execute_test --product mysql --version 5.7 --source
}
@test "check mysql 8.0 source" {
  execute_test --product mysql --version 8.0 --source
}

@test "check mariadb 10.2" {
  execute_test --product mariadb --version 10.2
}
@test "check mariadb 10.3" {
  execute_test --product mariadb --version 10.3
}
@test "check mariadb 10.4" {
  execute_test --product mariadb --version 10.4
}
@test "check mariadb 10.9" {
  execute_test --product mariadb --version 10.9
}
@test "check mariadb 10.10" {
  execute_test --product mariadb --version 10.10
}
@test "check mariadb 10.2 source" {
  execute_test --product mariadb --version 10.2 --source
}
@test "check mariadb 10.3 source" {
  execute_test --product mariadb --version 10.3 --source
}
@test "check mariadb 10.4 source" {
  execute_test --product mariadb --version 10.4 --source
}
@test "check mariadb 10.9 source" {
  execute_test --product mariadb --version 10.9 --source
}
@test "check mariadb 10.10 source" {
  execute_test --product mariadb --version 10.10 --source
}
@test "check mongodb 4.2" {
  execute_test --product mongodb --version 4.2 --distribution rhel70
}
@test "check mongodb 4.4" {
  execute_test --product mongodb --version 4.4 --distribution debian10
}
@test "check mongodb 5.0" {
  execute_test --product mongodb --version 5.0 --distribution ubuntu2004
}
@test "check mongodb 6.0" {
  execute_test --product mongodb --version 6.0  --distribution amazon2
}
@test "check mongodb 4.2 source" {
  execute_test --product mongodb --version 4.2 --source
}
@test "check mongodb 4.4 source" {
  execute_test --product mongodb --version 4.4 --source
}
@test "check mongodb 5.0 source" {
  execute_test --product mongodb --version 5.0 --source
}
@test "check mongodb 6.0 source" {
  execute_test --product mongodb --version 6.0 --source
}

@test "check proxysql 1.4" {
  execute_test --product proxysql --version 1.4
}
@test "check proxysql 1.4.14" {
  execute_test --product proxysql --version 1.4.14
}
@test "check proxysql source" {
  execute_test --product proxysql -s
}
@test "check proxysql 1.4 source" {
  execute_test --product  proxysql --version 1.4 -s
}
@test "check proxysql 1.4.14 source" {
  execute_test --product proxysql --version 1.4.14 -s
}
@test "check proxysql2" {
  execute_test --product proxysql
}
@test "check proxysql2 2.4" {
  execute_test --product proxysql2 --version 2.4
}
@test "check proxysql2 2.4.8" {
  execute_test --product proxysql2 --version 2.4.8
}
@test "check proxysql2 2.5" {
  execute_test --product proxysql2 --version 2.5
}
@test "check proxysql2 2.5.2" {
  execute_test --product proxysql2 --version 2.5.2
}
@test "check proxysql2 source" {
  execute_test --product proxysql2 -s
}
@test "check proxysql2 2.4 source" {
  execute_test --product proxysql2 --version 2.4 -s
}
@test "check proxysql2 2.4.8 source" {
  execute_test --product proxysql2 --version 2.4.8 -s
}
@test "check proxysql2 2.5 source" {
  execute_test --product proxysql2 --version 2.5 -s
}
@test "check proxysql2 2.5.2 source" {
  execute_test --product proxysql2 --version 2.5.2 -s
}

@test "check vault" {
  execute_test --product vault
}

@test "check postgresql" {
  execute_test --product postgresql
}

@test "check mysql 5.5 fails" {
  run ./get_download_link.sh --product mysql --version 5.5
  [ "$status" -eq 1 ]
}
@test "check mysql 5.6 fails" {
  run ./get_download_link.sh --product mysql --version 5.6
  [ "$status" -eq 1 ]
}
