#!bin/bash

export PGPASSWORD=postgres
export PGDATA=test_cluster
export PGPORT=5440
export PGHOST=/tmp

function cleanup() {
    pg_ctl -w stop -mf
    rm -fr $PGDATA $pwfile
    sed --in-place "s#$PGHBA#PGHBA_PLACEHOLDER#g" expected/pg_auth_mon.out
}

cleanup 2> /dev/null

set -e

readonly pwfile=$(mktemp)
echo -n $PGPASSWORD > $pwfile
initdb --pwfile=$pwfile --auth=md5

# prepare tests of pg_auth_mon.log_successful_authentications
cat >> test_cluster/postgresql.conf << EOF
pg_auth_mon.log_successful_authentications = 'on'
log_connections = 'off'
log_destination = 'csvlog'
log_directory = 'pg_log'
log_filename = 'postgresql'
logging_collector = 'on'
EOF

# the log line with a successful login info contains the full path to pg_hba.conf
# so we need to have it in the expected output to pass the tests
PGHBA=$(readlink -f test_cluster/pg_hba.conf)
# use an alternative separator for sed, namely #, because $PGHBA is itself a path with slashes
sed --in-place "s#PGHBA_PLACEHOLDER#$PGHBA#g" expected/pg_auth_mon.out

trap cleanup QUIT TERM EXIT
pg_ctl start -w -o "--shared_preload_libraries=pg_auth_mon --unix_socket_directories=$PGHOST"

make USE_PGXS=1 installcheck || diff -u expected/pg_auth_mon.out results/pg_auth_mon.out
