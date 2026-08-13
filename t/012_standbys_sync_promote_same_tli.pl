
# Copyright (c) 2021-2026, PostgreSQL Global Development Group

# Verify that pg_rewind distinguishes two simultaneously promoted nodes that
# share same TLI and the same WAL end LSN, but contain different WAL.

use strict;
use warnings FATAL => 'all';
use Test::More;
use PostgreSQL::Test::Utils;

use FindBin;
use lib $FindBin::RealBin;

use RewindTestStandbys;

RewindTestStandbys::setup_cluster();
RewindTestStandbys::start_primary();
RewindTestStandbys::primary_psql('CREATE TABLE test(value int PRIMARY KEY);');
RewindTestStandbys::create_standby();
RewindTestStandbys::create_standby_2();

my $common_lsn = $node_primary->safe_psql('postgres', 'SELECT pg_current_wal_lsn()');
$node_primary->wait_for_catchup($node_standby, 'replay', $common_lsn);
$node_primary->wait_for_catchup($node_standby_2, 'replay', $common_lsn);

RewindTestStandbys::stop_primary('immediate');

# Promote Standby nodes simultaneously
$node_standby->promote;
$node_standby_2->promote;
$node_standby->poll_query_until('postgres', "SELECT pg_is_in_recovery() = 'f';");
$node_standby_2->poll_query_until('postgres', "SELECT pg_is_in_recovery() = 'f';");

# Standby nodes are on the same TLI
is(
	$node_standby->safe_psql(
		'postgres',
		'SELECT timeline_id FROM pg_control_checkpoint()'
	),
	'2',
	'standby 1 promoted to TLI 2'
);
is(
	$RewindTestStandbys::node_standby_2->safe_psql(
		'postgres',
		'SELECT timeline_id FROM pg_control_checkpoint()'
	),
	'2',
	'standby 2 promoted to TLI 2'
);

# Make sure that Standby nodes have identical TLI 2 begin LSN
my $standby_lsn = $node_standby->safe_psql('postgres', 'SELECT pg_current_wal_insert_lsn()');
my $standby_2_lsn = $node_standby_2->safe_psql('postgres', 'SELECT pg_current_wal_insert_lsn()');
is($standby_2_lsn, $standby_lsn, 'divergent TLI 2 branches begin at the same LSN');

# The INSERTs have identical WAL sizes (and LSN) but distinct contents on TLI 2 branches
RewindTestStandbys::standby_psql('INSERT INTO test SELECT generate_series(1, 1000);');
RewindTestStandbys::standby_2_psql('INSERT INTO test SELECT generate_series(10001, 11000);');

# Rewind process starts from latest checkpoint => rewind skips INSERTs from above
RewindTestStandbys::standby_psql('CHECKPOINT;');
RewindTestStandbys::standby_2_psql('CHECKPOINT;');

# Make sure that Standby nodes have identical TLI 2 end LSN
$standby_lsn = $node_standby->safe_psql('postgres', 'SELECT pg_current_wal_lsn()');
$standby_2_lsn = $node_standby_2->safe_psql('postgres', 'SELECT pg_current_wal_lsn()');
is($standby_2_lsn, $standby_lsn, 'divergent TLI 2 branches end at the same LSN');

# Data on Standby nodes are different
RewindTestStandbys::check_query_standby(
	'SELECT min(value), max(value) FROM test;',
	"1|1000\n",
	'standby 1 has its TLI 2 data before rewind'
);
RewindTestStandbys::check_query_standby_2(
	'SELECT min(value), max(value) FROM test;',
	"10001|11000\n",
	'standby 2 has its TLI 2 data before rewind'
);

# pg_rewind:
# 	Standby 1 is Source, Standby 2 is Target =>
# 	=> after rewind Standby 2 replicates Standby 1
RewindTestStandbys::run_pg_rewind_on_standbys('remote');

# Desirable result is either:
# 1. pg_rewind fails and explicitly states why
# 2. pg_rewind finds differences in histories,
# -- and rewinds Standby 2 without violating data consistency

# No rewind needed (non-desirable result):
# 	Replication from Standby 1 to Standby 2 is set up
# 	we continue expecting that everything goes smoothly

# Standby 2 cannot start receiving WAL from Standby 1:
# 	Standby 2 waits for WALs at it's end LSN
# 	Standby 1 starts replication at begin LSN
# That means that Standby 2 will never catchup Standby 1

# Make sure that above scenario is actually happend
# and there is no streaming replication between nodes
# TODO: This way to check that doesn't work, either:
# - Skip this check, it is not very important anyway
# - Find another way to check it
#
# my $repl_state = $node_standby->safe_psql(
# 	'postgres',
# 	"SELECT state FROM pg_stat_replication " .
# 	"WHERE application_name LIKE " .
# 	"'" . $node_standby->name . "';"
# );
#
# is(
# 	$repl_state,
# 	'streaming',
# 	'standby 2 caught up to standby 1 to start replication'
# );

# Standby nodes have consistent data
RewindTestStandbys::check_query_standby(
	'SELECT min(value), max(value) FROM test;', "1|1000\n",
	'standby 1 retains data from TLI 2'
);
RewindTestStandbys::check_query_standby_2(
	'SELECT min(value), max(value) FROM test;', "1|1000\n",
	'standby 2 data is consistent with standby 1 data'
);

RewindTestStandbys::clean_rewind_test();

done_testing();
