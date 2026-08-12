#!/bin/bash

WDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/hash-example-wdir

rm -rf $WDIR
mkdir $WDIR

primary=$WDIR/primary
standby1=$WDIR/standby1
standby2=$WDIR/standby2
archivedir=$WDIR/archivedir

rm -rf $archivedir
mkdir $archivedir

echo "=========================================="
echo "= WARNING:                               ="
echo "= Apply patches/hash-segment-wip.patch   ="
echo "=  before launch!                        ="
echo "=========================================="

echo "=========================================="
echo "========== Initializing Primary =========="
echo "=========================================="

rm -rf $primary $standby1 $standby2
initdb $primary

echo "=========================================="
echo "============ Starting Primary ============"
echo "=========================================="

echo "archive_command = 'test ! -f $archivedir/%f && cp %p $archivedir/%f'" >>$primary/postgresql.conf
pg_ctl -D $primary -l $primary/pg.log start

sleep 1

echo "=========================================="
echo "=========== Creating Standbys ============"
echo "=========================================="

pg_basebackup -D $standby1 -R
pg_basebackup -D $standby2 -R

echo "port = 5433" >>$standby1/postgresql.conf
echo "restore_command = 'test ! -f %p && cp $archivedir/%f %p'" >>$standby1/postgresql.conf

echo "port = 5434" >>$standby2/postgresql.conf
echo "restore_command = 'test ! -f %p && cp $archivedir/%f %p'" >>$standby2/postgresql.conf

echo "=========================================="
echo "============ Starting Standbys ==========="
echo "=========================================="

pg_ctl -D $standby1 -l $standby1/pg.log start
pg_ctl -D $standby2 -l $standby2/pg.log start

echo "=========================================="
echo "============ Hash on Primary ============="
echo "=========================================="
psql -d postgres -h /tmp -p 5432 -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "=========== Hash on Standby 1 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5433 -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "=========== Hash on Standby 2 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5434 -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "========= Transactions on Primary ========"
echo "=========================================="

psql -d postgres -h /tmp -p 5432 -c "CREATE TABLE test (value INT PRIMARY KEY);"
psql -d postgres -h /tmp -p 5432 -c "INSERT INTO test SELECT generate_series(1, 200000);"

sleep 3

echo "=========================================="
echo "============ Crashing Primary ============"
echo "=========================================="

pg_ctl -D $primary stop -m immediate

echo "=========================================="
echo "============ Hash on Primary ============="
echo "=========================================="
psql -d postgres -h /tmp -p 5432 -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "=========== Hash on Standby 1 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5433 -e -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "=========== Hash on Standby 2 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5434 -e -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "=========== Promoting Standbys ==========="
echo "=========================================="
echo "= WAL streamed from Primary is identical ="
echo "=  for both Standbys, so hashes at the   ="
echo "=  end of TimeLine 1 must be similar     ="
echo "=========================================="

pg_ctl -D $standby1 promote
pg_ctl -D $standby2 promote

echo "=========================================="
echo "=========== Hash on Standby 1 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5433 -e -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "=========== Hash on Standby 2 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5434 -e -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "======== Transcations on Standbys ========"
echo "=========================================="
echo "= Starting from here TimeLine hashes     ="
echo "=  on Standbys must be different         ="
echo "=========================================="

psql -d postgres -h /tmp -p 5433 -e -c "INSERT INTO test SELECT generate_series(200001, 300000);"
psql -d postgres -h /tmp -p 5434 -e -c "INSERT INTO test SELECT generate_series(300001, 400000);"

echo "=========================================="
echo "=========== Hash on Standby 1 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5433 -e -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "=========== Hash on Standby 2 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5434 -e -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "======= Switching TLs on Standbys ========"
echo "=========================================="

pg_ctl -D $standby1 -l $standby1/pg.log stop
pg_ctl -D $standby2 -l $standby2/pg.log stop

touch $standby1/standby.signal
touch $standby2/standby.signal

pg_ctl -D $standby1 -l $standby1/pg.log start
pg_ctl -D $standby2 -l $standby2/pg.log start

sleep 1

pg_ctl -D $standby1 -l $standby1/pg.log promote
pg_ctl -D $standby2 -l $standby2/pg.log promote

sleep 1

echo "=========================================="
echo "=========== Hash on Standby 1 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5433 -e -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "=========== Hash on Standby 2 ============"
echo "=========================================="
psql -d postgres -h /tmp -p 5434 -e -c "SELECT * FROM pg_control_hash();"

echo "=========================================="
echo "============ Stopping Standbys ==========="
echo "=========================================="

pg_ctl -D $standby1 -l $standby1/pg.log stop
pg_ctl -D $standby2 -l $standby2/pg.log stop

echo "=========================================="
echo "=========== Standby 1 History ============"
echo "=========================================="
cat $standby1/pg_wal/00000003.history

echo "=========================================="
echo "=========== Standby 2 History ============"
echo "=========================================="
cat $standby2/pg_wal/00000003.history
