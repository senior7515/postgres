use strict;
use warnings;

use PostgresNode;
use TestLib;
use Test::More;
use IPC::Run qw(pump finish timer);

if (!defined($ENV{with_readline}) || $ENV{with_readline} ne 'yes')
{
	plan skip_all => 'readline is not supported by this build';
}

# If we don't have IO::Pty, forget it, because IPC::Run depends on that
# to support pty connections
eval { require IO::Pty; };
if ($@)
{
	plan skip_all => 'IO::Pty is needed to run this test';
}

# start a new server
my $node = get_new_node('main');
$node->init;
$node->start;

# set up a few database objects
$node->safe_psql('postgres',
	    "CREATE TABLE tab1 (f1 int, f2 text);\n"
	  . "CREATE TABLE mytab123 (f1 int, f2 text);\n"
	  . "CREATE TABLE mytab246 (f1 int, f2 text);\n");

# Developers would not appreciate this test adding a bunch of junk to
# their ~/.psql_history, so be sure to redirect history into a temp file.
# We might as well put it in the test log directory, so that buildfarm runs
# capture the result for possible debugging purposes.
my $historyfile = "${TestLib::log_path}/010_psql_history.txt";
$ENV{PSQL_HISTORY} = $historyfile;

# fire up an interactive psql session
my $in  = '';
my $out = '';

my $timer = timer(5);

my $h = $node->interactive_psql('postgres', \$in, \$out, $timer);

ok($out =~ /psql/, "print startup banner");

# Simple test case: type something and see if psql responds as expected
sub check_completion
{
	my ($send, $pattern, $annotation) = @_;

	# reset output collector
	$out = "";
	# restart per-command timer
	$timer->start(5);
	# send the data to be sent
	$in .= $send;
	# wait ...
	pump $h until ($out =~ m/$pattern/ || $timer->is_expired);
	my $okay = ($out =~ m/$pattern/ && !$timer->is_expired);
	ok($okay, $annotation);
	# for debugging, log actual output if it didn't match
	note 'Actual output was "' . $out . "\"\n" if !$okay;
	return;
}

# Clear query buffer to start over
# (won't work if we are inside a string literal!)
sub clear_query
{
	check_completion("\\r\n", "postgres=# ", "\\r works");
	return;
}

# check basic command completion: SEL<tab> produces SELECT<space>
check_completion("SEL\t", "SELECT ", "complete SEL<tab> to SELECT");

clear_query();

# check case variation is honored
check_completion("sel\t", "select ", "complete sel<tab> to select");

# check basic table name completion
check_completion("* from t\t", "\\* from tab1 ", "complete t<tab> to tab1");

clear_query();

# check table name completion with multiple alternatives
# note: readline might print a bell before the completion
check_completion(
	"select * from my\t",
	"select \\* from my\a?tab",
	"complete my<tab> to mytab when there are multiple choices");

# some versions of readline/libedit require two tabs here, some only need one
check_completion("\t\t", "mytab123 +mytab246",
	"offer multiple table choices");

check_completion("2\t", "246 ",
	"finish completion of one of multiple table choices");

clear_query();

# check case-sensitive keyword replacement
# XXX the output here might vary across readline versions
check_completion(
	"\\DRD\t",
	"\\DRD\b\b\bdrds ",
	"complete \\DRD<tab> to \\drds");

clear_query();

# send psql an explicit \q to shut it down, else pty won't close properly
$timer->start(5);
$in .= "\\q\n";
finish $h or die "psql returned $?";
$timer->reset;

# done
$node->stop;
done_testing();
