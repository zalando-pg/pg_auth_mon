create role auth_super with superuser login password 'postgres';
create role auth_nologin with password 'postgres';
create role auth_test with login password 'wrongpassword';
create role auth_to_be_deleted with login password 'foobar';
create role auth_to_be_renamed with login password 'postgres';

create database testdb;

create extension pg_auth_mon version '1.0';

create extension file_fdw schema public;
create server pglog foreign data wrapper file_fdw;
create foreign table public.postgres_log (
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
) server pglog
options ( filename 'pg_log/postgresql.csv', format 'csv' );

do $$declare version int;
begin
    version:=current_setting('server_version_num')::int/10000;
    if version >= 13 then
        execute 'alter table public.postgres_log add column if not exists backend_type text;';
    end if;
    if version >= 14 then
        execute 'alter table public.postgres_log add column if not exists leader_pid integer;';
        execute 'alter table public.postgres_log add column if not exists query_id bigint;';
    end if;
end $$;

--1.Successful Login attempt
\! PGPASSWORD=postgres psql -X -U auth_super -d testdb -c "select 1"
select rolname, successful_attempts, total_hba_conflicts, other_auth_failures from pg_auth_mon where rolname like 'auth_%';

--2.Login attempt by invalid username
\! PGPASSWORD=postgres psql -X -U auth_blah -d testdb  -c "select 1" 2>&1 | sed 's/^.* FATAL: */FATAL: /'
select rolname, uid, successful_attempts, total_hba_conflicts, other_auth_failures from pg_auth_mon where uid = 0;

--3.Login attempt by username who is not allowed to login is not authentication failure
\! PGPASSWORD=postgres psql -X -U auth_nologin -d testdb -c "select 1" 2>&1 | sed 's/^.* FATAL: */FATAL: /'
select rolname, successful_attempts, total_hba_conflicts, other_auth_failures from pg_auth_mon where rolname like 'auth_%' order by rolname;

--4.Login attempt by a valid user with a wrong password 
\! PGPASSWORD=postgres psql -X -U auth_test -d testdb -c "select 1" 2>&1 | sed 's/^.* FATAL: */FATAL: /'
select rolname, successful_attempts, total_hba_conflicts, other_auth_failures from pg_auth_mon where rolname like 'auth_%' order by rolname;

--5. Test upgrade to version '1.1'
alter extension pg_auth_mon update to '1.1';
select extversion from pg_extension where extname = 'pg_auth_mon';
-- ensure the data from the previous version is still accessible
select rolname, successful_attempts, total_hba_conflicts, other_auth_failures from pg_auth_mon where rolname like 'auth_%' order by rolname;

--6. Rolname is not empty for deleted users
\! PGPASSWORD=foobar psql -X -U auth_to_be_deleted -d testdb -c "select 1"
drop role auth_to_be_deleted;
select rolname, successful_attempts, total_hba_conflicts, other_auth_failures from pg_auth_mon where rolname like 'auth_%' order by rolname;

--7. The rolname at the last login attempt (not the initial one) is shown when a role is renamed before deletion
\! PGPASSWORD=postgres psql -X -U auth_to_be_renamed -d testdb -c "select 1"
alter role auth_to_be_renamed rename to auth_renamed;
alter role auth_renamed with password 'postgres';
\! PGPASSWORD=postgres psql -X -U auth_renamed -d testdb -c "select 1"
drop role auth_renamed;
select rolname, successful_attempts, total_hba_conflicts, other_auth_failures from pg_auth_mon where rolname like 'auth_%' order by rolname;

--8. Successful logins are logged with and without SSL
\! PGPASSWORD=postgres PGSSLMODE=require psql -X -U auth_super -h 127.0.0.1 -d testdb -c "select 1"
\t
SELECT regexp_replace( message, ':\d{1,5}', ':', 'g' ) from public.postgres_log where message like '%auth\_super%';
\t

--9. Check if the amount of log entries for the log-in attempts done in the previous test cases is correct.
-- auth_to_be_renamed and auth_renamed have the same oid, and pg_auth_mon aggregates based on oids
-- hence 2 succesfful login attempts for auth_renamed in the previous test
select user_name, count(*) as ct from public.postgres_log where position('connection authorized' in message) > 0 and user_name like 'auth%' group by user_name order by ct desc;

--Cleanup
drop role auth_nologin;
drop role auth_test;
drop role auth_super;
drop extension file_fdw cascade;
drop database testdb;
