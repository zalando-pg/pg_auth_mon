#!bin/bash

export PGPASSWORD=postgres
export PGDATA=test_cluster
export PGPORT=5440
export PGHOST=/tmp

function cleanup() {
    pg_ctl -w stop -mf
    rm -fr $PGDATA $pwfile
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
ssl = 'on'
ssl_ciphers = 'DHE-RSA-AES256-GCM-SHA384:!SSLv1:!SSLv2:!SSLv3:!TLSv1:!TLSv1.1'
ssl_prefer_server_ciphers = 'on'
EOF

echo "hostssl    all             all             127.0.0.1/32            md5" >> $PGDATA/pg_hba.conf

openssl req -nodes -new -x509 -subj /CN=pg_auth_mon.example.org -keyout server.key -out server.crt
chmod 600 server.key
mv server.key server.crt $PGDATA


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

# we have to modify the expected values depending on PG version
EXPECTED=expected/pg_auth_mon.out

# the log line with a successful login info contains the full path to pg_hba.conf
# so we need to have it in the expected output to pass the tests
PGHBA=$(readlink -f $PGDATA/pg_hba.conf)
# use an alternative separator for sed, namely #, because $PGHBA is itself a path with slashes
sed --in-place "s#PGHBA_PLACEHOLDER#$PGHBA#g" $EXPECTED

SSL='compression=off'
if [ "$PGVER" -ge 11 ]; then
    SSL='bits=256'
fi
sed --in-place "s#SSL_PLACEHOLDER#$SSL#g" $EXPECTED

APPLICATION_NAME=''
if [ "$PGVER" -ge 12 ]; then
    APPLICATION_NAME='application_name=pg_regress/pg_auth_mon'
fi
sed --in-place "s#APPLICATION_NAME_PLACEHOLDER#$APPLICATION_NAME#g" $EXPECTED

IDENTITY=''
if [ "$PGVER" -ge 14 ]; then
    IDENTITY='identity=auth_super'
fi
sed --in-place "s#IDENTITY_PLACEHOLDER#$IDENTITY#g" $EXPECTED

make USE_PGXS=1 installcheck || diff -u $EXPECTED results/pg_auth_mon.out
