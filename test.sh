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

# set up the postgres_log table. A simplified version of spilo/postgres-appliance/scripts/post_init.sh
PGVER=$(psql -d postgres -XtAc "SELECT pg_catalog.current_setting('server_version_num')::int/10000")
(
echo "
create extension file_fdw schema public;
create server pglog foreign data wrapper file_fdw;
CREATE FOREIGN TABLE public.postgres_log (
  log_time timestamp(3) with time zone,
  user_name text,
  database_name text,
  process_id integer,
  connection_from text,
  session_id text,
  session_line_num bigint,
  command_tag text,
  session_start_time timestamp with time zone,
  virtual_transaction_id text,
  transaction_id bigint,
  error_severity text,
  sql_state_code text,
  message text,
  detail text,
  hint text,
  internal_query text,
  internal_query_pos integer,
  context text,
  query text,
  query_pos integer,
  location text,
  application_name text
) SERVER pglog
OPTIONS ( filename 'pg_log/postgresql.csv', format 'csv' );
"

if [ "$PGVER" -ge 13 ]; then
    echo "ALTER TABLE public.postgres_log ADD COLUMN IF NOT EXISTS backend_type text;"
fi

if [ "$PGVER" -ge 14 ]; then
    echo "ALTER TABLE public.postgres_log ADD COLUMN IF NOT EXISTS leader_pid integer;"
    echo "ALTER TABLE public.postgres_log ADD COLUMN IF NOT EXISTS query_id bigint;"
fi

) | psql -d postgres -X

make USE_PGXS=1 installcheck || diff -u expected/pg_auth_mon.out results/pg_auth_mon.out
