#!/usr/bin/perl -w
#
# Copyright (c) 2000-2024 University of Utah and the Flux Group.
# 
# {{{EMULAB-LICENSE
# 
# This file is part of the Emulab network testbed software.
# 
# This file is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
# 
# This file is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
# License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this file.  If not, see <http://www.gnu.org/licenses/>.
# 
# }}}
#
use English;
use strict;
use Getopt::Std;
use Data::Dumper;
use POSIX;

#
# Run this on the cn5g node
#
sub usage()
{
    print "Usage: start-iperf.pl [-R]\n";
    exit(1);
}
my $optlist   = "R";
my $TMPDIR    = "/var/tmp";
my $IPERFIP   = "10.45.0.1";

my %options = ();
if (! getopts($optlist, \%options)) {
    die("usage");
}

if (! -e "/bin/daemon") {
    system("sudo apt-get -y install --no-install-recommends daemon");
    if ($?) {
	die("Could not install daemon\n");
    }
}
if (! -e "/var/www/html/random-data") {
    system("sudo dd if=/dev/random ".
	   "        of=/var/www/html/random-data bs=64k count=200");
    if ($?) {
	die("Could not create /var/www/html/random-data\n");
    }
}
my $port = 5000;
my $pidfile = "$TMPDIR/iperf.pid";

if (defined($options{"R"})) {
    if (-e $pidfile) {
	my $pid = `/bin/cat $pidfile`;
	chomp($pid);
	system("sudo kill $pid");
	sleep(1);
    }
}
print "Starting iperf server port $port\n";
my $command =
    "daemon -N -r -n iperf-server --delay=15 ".
    "   --output=$TMPDIR/iperf.log ".
    "   --pidfile=$pidfile -- ".
    " /usr/local/bin/iperf3 -s -p $port -B $IPERFIP --forceflush ".
    "   --rcv-timeout 30000 --snd-timeout 30000 ";
print "$command\n";
system($command);
if ($?) {
    die("Could not start iperf server on port $port");
}
