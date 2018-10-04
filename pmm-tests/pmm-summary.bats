@test "run pmm-admin summary under regular(non-root) user privileges" {
if [[ $(id -u) -eq 0 ]] ; then
	skip "Skipping this test, because you are running under root"
fi
run pmm-admin summary
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "pmm-admin requires superuser privileges to manage system services." ]
}

@test "run pmm-admin summary under root privileges" {
if [[ $(id -u) -ne 0 ]] ; then
	skip "Skipping this test, because you are NOT running under root"
fi
run pmm-admin summary
echo "$output"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "Data collection complete"
}


@test "extract the client diagnostics files" {
if [[ $(id -u) -ne 0 ]] ; then
  skip "Skipping this test, because you are NOT running under root"
fi
CLIENT_NAME=$(pmm-admin list | grep 'Client Name' | cut -d'|' -f 2 | xargs)
run bash -c "tar -xvf summary_${CLIENT_NAME}*.tar.gz"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "pmm-admin_check-network"
    echo "${output}" | grep "pmm-admin_list"
    echo "${output}" | grep "ps_exporter"
    echo "${output}" | grep "pt-summary_"
}

@test "extract the server diagnostics files" {
if [[ $(id -u) -ne 0 ]] ; then
  skip "Skipping this test, because you are NOT running under root"
fi
SERVER=$(pmm-admin list | grep 'PMM Server' | cut -d'|' -f 2 | xargs)
if [ -f logs.zip ] ; then
    rm logs.zip
fi
run bash -c "wget "http://${SERVER}/managed/logs.zip""
run bash -c "unzip -o logs.zip"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "inflating: grafana.log"
    echo "${output}" | grep "inflating: createdb.log" 
}

function teardown() {
  echo "$output"
}