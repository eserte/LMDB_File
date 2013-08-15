#!perl
use Test::More tests => 106;
use Test::Exception;
use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);

use LMDB_File qw(:envflags :cursor_op);

throws_ok {
    LMDB::Env->new("NoSuChDiR");
} qr/No such file/, 'Directory must exists';

my $testdir = 'TestDir';
my $dir = tempdir('mdbtXXXX', TMPDIR => 1);
ok(-d $dir, "Created $dir");

throws_ok {
    LMDB::Env->new($dir, { flags => MDB_RDONLY });
} qr/No such/, 'RO must exists';
#is(scalar @{[ glob "$dir/*" ]}, 0,  'Dir empty');

{
    my $env = new_ok('LMDB::Env' => [ $dir ], "Create Environment");
    ok(-e "$dir/data.mdb", 'Data file created exists');
    ok(-e "$dir/lock.mdb", 'Lock file created exists');
    $env->get_path(my $dumy);
    is($dir, $dumy, 'get_path');
    $env->get_flags($dumy);
    is($dumy, 0x30000000, 'Flags setted'); # Using private
    ok($env->id, 'Env ID: ' . $env->id);

    #throws_ok {
    #	LMDB::Env->new($dir);
    #} qr/ready/, 'Already opened in this proccess';

    # Basic Environment info
    isa_ok(my $envinfo = $env->info, 'HASH', 'Get Info');
    ok(exists $envinfo->{$_}, "Info has $_")
	for qw(mapaddr mapsize last_pgno last_txnid maxreaders numreaders);
    ok(!exists $envinfo->{SomeOther}, 'Not in info');

    is($envinfo->{mapaddr}, 0, 'Not mapfixed');
    is($envinfo->{mapsize}, 1024 * 1024, 'Stock mapsize');
    is($envinfo->{maxreaders}, 126, 'Default maxreders');
    is($envinfo->{numreaders}, 0, 'No readers');

    isa_ok(my $stat = $env->stat, 'HASH', 'Get Stat');
    ok(exists $stat->{$_}, "Stat has $_")
	for qw(psize depth branch_pages leaf_pages overflow_pages entries);
    is($stat->{psize}, 4096, 'Default psize');
    is($stat->{$_}, 0, "$_ = 0, empty")
	for qw(depth branch_pages leaf_pages overflow_pages entries);

    is(Internals::SvREFCNT($$env), 1, 'Env Inactive');
    isa_ok(my $txn = $env->BeginTxn, 'LMDB::Txn', 'Transaction');
    is(Internals::SvREFCNT($$env), 2, 'Env Active');

    {
    	isa_ok(my $sub = $env->BeginTxn, 'LMDB::Txn', 'Subtransaction');
	is(Internals::SvREFCNT($$env), 3, 'Env Active');
    }
    throws_ok {
	$txn->OpenDB('NAMED');
    } qr/limit reached/, 'No named allowed';

    {
	isa_ok(my $eclone = $txn->env, 'LMDB::Env', 'Got Env');
	is($env->id, $eclone->id, "The same ID ($$env)");
	is(Scalar::Util::refaddr($env), Scalar::Util::refaddr($eclone), 'Same refaddr');
	is(Internals::SvREFCNT($$env),  3, 'Refcounted');
    }
    is(Internals::SvREFCNT($$env), 2, 'Back normal');

    # Open main dbi
    isa_ok(my $dbi = $txn->OpenDB, 'LMDB_File', 'DBI created');
    is($dbi->alive, 1, 'The first');
    is($dbi->flags, 0, 'Main DBI Flags');
    is($env->info->{numreaders}, 0, "I'm not a reader");

    is($txn->OpenDB->alive, $dbi->alive, 'Just a clone');

    # Put some data
    my %data;
    my $c;
    foreach('A' .. 'Z') {
	$c = ord($_) - ord('A') + 1;
	my $k = $_ x 4;
	my $v = sprintf('Datum #%d', $c);
	$data{$k} = $v; # Keep a copy, for testing
	if($c < 4) {
	    is($dbi->put($k, $v), $v, "Put $k");
	    is($dbi->stat->{entries}, $c, "Entry $c");
	} else {
	    # Don't be verbose
	    $dbi->put($k, $v);
	}
    }
    is($c, 26, 'All in');
    # Check data in random HASH order
    $c = 5; # Don't be verbose
    while(my($k, $v) = each %data) {
	is($dbi->get($k), $v, "Get $k") if(--$c >= 0);
    }

    # Commit
    lives_ok { $txn->commit; }  'Commited';

    # Commit terminates transaction
    throws_ok {
	$dbi->get('SOMEKEY');
    } qr/Not an active/, 'Commit finalized dbi';
    throws_ok {
	$txn->OpenDB;
    } qr/Not an active/, 'Commit finalized txn';
    is(Internals::SvREFCNT($$env), 1, 'Env Inactive');

    # Test copy method
    throws_ok {
	$env->copy($testdir);
    } qr/No such/, 'Copy needs a directory';
    throws_ok {
	$env->copy($dir);
    } qr/File exists/, 'An empty one, not myself';
    mkdir $testdir;
    is($env->copy($testdir), 0, 'Copied');
    ok(-e "$testdir/data.mdb", "Data file created");

    open(my $fd, '>', "$testdir/other.mdb");
    is($env->copyfd($fd), 0, 'Copied to HANDLE');
}

{
    my $env = LMDB::Env->new($testdir, {
	    mapsize => 2 * 1024 * 1024,
	    flags => MDB_RDONLY
    });
    isa_ok($env, 'LMDB::Env');
    is($env->info->{mapsize}, 2 * 1024 * 1024, 'mapsize increased');
    is($env->info->{numreaders}, 0, 'No yet');

    isa_ok(my $dbi = $env->BeginTxn->OpenDB, 'LMDB_File', 'RO DBI opened');
    throws_ok {
	$dbi->put('0000', 'Datum #0');
    } qr/Permission denied/, 'Read only transaction';

    is($env->info->{numreaders}, 1, "I'm a reader");
    is($dbi->stat->{entries}, 26, 'Has my data');

    # Read using cursors
    isa_ok(my $cursor = $dbi->OpenCursor, 'LMDB::Cursor', 'A cursor');
    is($cursor->dbi, $dbi->alive, 'Get DBI');

    $cursor->get(my $key, my $datum, MDB_FIRST);
    is($key, 'AAAA', 'First key');
    is($datum, 'Datum #1', 'First datum');
    throws_ok {
	$cursor->get($key, $datum, MDB_PREV);
    } qr/NOTFOUND/, 'No previous key';
    $cursor->get($key, $datum, MDB_NEXT);
    is($key, 'BBBB', 'Next key');
    is($datum, 'Datum #2', 'Next datum');
    $cursor->get($key, $datum, MDB_LAST);
    is($key, 'ZZZZ', 'Last key');
    is($datum, 'Datum #26', 'Last datum');
    $cursor->get($key, $datum, MDB_PREV);
    is($key, 'YYYY', 'Previous key');
    is($datum, 'Datum #25', 'Previous datum');
    $key = $datum = '';
    $cursor->get($key, $datum, MDB_GET_CURRENT);
    is($key, 'YYYY', 'Current key');
    is($datum, 'Datum #25', 'Current datum');

    throws_ok {
	# Most cursor_ops need to return the key
	$cursor->get('CCCC', $datum, MDB_GET_CURRENT);
    } qr/read-only value/, 'Need lvalue';
    lives_ok {
	# Some accept a constant
	$cursor->get('CCCC', $datum, MDB_SET);
    } 'Can be constant';
    is($datum, 'Datum #3', 'lookup datum');

    throws_ok {
	$cursor->get($key = 'ZABC', $datum, MDB_SET);
    } qr/NOTFOUND/, 'Not found';
    $cursor->get($key, $datum, MDB_SET_RANGE);
    is($key, 'ZZZZ', 'Got last key');
    is($datum, 'Datum #26', 'Got last datum');
    throws_ok {
	$cursor->get($key, $datum, MDB_NEXT);
    } qr/NOTFOUND/, 'No next key';
}
{
    # Using TIE interface
    my $h;
    isa_ok(
	tie(%$h, 'LMDB_File', "$testdir/other.mdb" => { flags => MDB_NOSUBDIR }),
	'LMDB_File', 'Tied'
    );
    isa_ok(tied %$h, 'LMDB_File', 'The same');

    is($h->{EEEE}, 'Datum #5', 'FETCH');
    is($h->{ABCS}, undef, 'No data');
    my @keys = keys %{$h};
    is(scalar @keys, 26, 'Correct size');

    ok(exists $h->{ZZZZ}, 'Exists');
    is(delete $h->{ZZZZ}, 'Datum #26', 'Deleted #26');
    ok(!exists $h->{ZZZZ}, 'Really deleted');

    untie %$h;
}

END {
    unless($ENV{KEEP_TMPS}) {
	for($dir, $testdir) {
	    unlink glob("$_/*");
	    rmdir or warn "rm: $!\n";
	    warn "Removed $_\n";
	}
    }
}
