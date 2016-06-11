# $Id: 55_DWD.pm 0 2016-05-08 00:00:00Z premultiply $
####################################################################################################
#
#	55_DWD.pm
#
#	An FHEM Perl module to retrieve actual data from "Deutscher Wetterdienst"
#
#	Copyright: premultiply
#
#   This file is part of fhem.
#
#   Fhem is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 2 of the License, or
#   (at your option) any later version.
#
#   Fhem is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
####################################################################################################
# copyright and license informations


package main;

use strict;
use warnings;

use feature "switch";

use Encode;
use Net::FTP;
use HTML::Entities;
use HTML::TableExtract;

my ($sList);

sub DWD_Initialize($) {
	my ($hash) = @_;

	#$hash->{internals}{interfaces}= "temperature:humidity";
	#$hash->{fhem}{interfaces}= "temperature;humidity";

	$hash->{DefFn}		=	"DWD_Define";
	$hash->{UndefFn}	=	"DWD_Undef";
	$hash->{GetFn}		=	"DWD_Get";
	$hash->{SetFn}		=	"DWD_Set";

	$hash->{AttrList} .= "disable:0,1 station ".$readingFnAttributes;
}

sub DWD_Define($$) {
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);

	return "syntax: define <name> DWD <username> <password> [<interval> [<host>]]"  if ( int(@a) < 4 or int(@a) > 6 );

	my $name = $a[0];

	my $interval = 1800;
	if ( int(@a) >= 4 ) { $interval = $a[4]; }
	if ( $interval < 300 ) { $interval = 300; }

	$hash->{USERNAME} = $a[2];
	$hash->{PASSWORD} = $a[3];
	$hash->{HOST} = defined($a[5]) ? $a[5] : "ftp-outgoing2.dwd.de";
	$hash->{INTERVAL} = $interval;

	$hash->{STATE} = "Initialized";

	DWD_PollTimer($hash);

	return undef;
}

sub DWD_Undef($$) {
	my ($hash, $arg) = @_;

	RemoveInternalTimer($hash);
	return undef;
}

sub DWD_Get($@) {
	my ($hash, @a) = @_;
	my $name = $hash->{NAME};
	my $usage =	"Unknown argument, choose one of ".
				"actual:noArg ".
				#"summary1h:noArg ".
				#"summary12h:noArg ".
				"summary24h:noArg ";

	my $command = lc($a[1]);

	given($command) {
		when("actual") {
			DWD_RetrieveData($hash, '4_U');
			break;
			}
		when("summary1h") {
			DWD_RetrieveData($hash, '14_U');
			break;
			}
		when("summary12h") {
			DWD_RetrieveData($hash, '(?:06|18)14_U');
			break;
			}
		when("summary24h") {
			DWD_RetrieveData($hash, '0645');
			break;
			}
		default { return $usage; };
	}

	return undef;
}

sub DWD_Set($@) {
	my ($hash, @a) = @_;
	my $name = $hash->{NAME};
	my $usage =	"Unknown argument, choose one of ".
				"clear:noArg ".
				"station:$sList ".
				"update:noArg ";

	my $command = lc($a[1]);
	my $parameter = $a[2] if(defined($a[2]));

	given($command) {
		when("clear") {
			CommandDeleteReading(undef, "$name _.*");
			break;
			}
		when("update") {
			DWD_PollTimer($hash);
			break;
			}
		when("station") {
			$attr{$name}{station} = $parameter;
			DWD_PollTimer($hash);
			break;
			}
		default { return $usage; };
	}

	return undef;
}

sub DWD_RetrieveData($$) {
	my ($hash, $pattern) = @_;
	my $name = $hash->{NAME};

	my $fc;

	my $proxyHost	= AttrVal($name, "proxyHost", "");
	my $proxyType	= AttrVal($name, "proxyType", "");
	my $passiveFTP	= AttrVal($name, "passiveFTP", 1);

	eval {
		my $ftp = Net::FTP->new($hash->{HOST},
								Debug        => 0,
								Timeout      => 10,
								Passive      => $passiveFTP,
								FirewallType => $proxyType,
								Firewall     => $proxyHost);
		if (defined($ftp)) {
			$ftp->login($hash->{USERNAME}, $hash->{PASSWORD});
			$ftp->cwd("gds/specials/observations/tables/germany/");
			$ftp->binary;

			my @files = grep /SXDL99_DWAV_.*${pattern}_HTML$/, $ftp->ls();

			if (@files) {
				@files = reverse(sort(@files));
				my $datafile = shift(@files);
				Log3 $hash, 1, "file to download: $datafile";
				my ($file_content, $file_handle);
				open($file_handle, '>', \$file_content);
				$ftp->get($datafile, $file_handle);
				$fc = decode_entities(decode('ISO-8859-1', $file_content));
				
				my $te = HTML::TableExtract->new();
				$te->parse($fc);
				my $table = $te->first_table_found();

				my @data = $table->rows;

				my @header = @{shift(@data)};
				map(s/[^\w]//g, @header);

				my @stations;
				push(@stations, @{$_}[0]) for (@data);
				map(s/\s/_/g, @stations);

				my $selstation;
				
				foreach (@data) {
					$selstation = @{$_}[0];
					$selstation =~ s/\s/_/g;
					if ( encode('UTF-8', $selstation) eq AttrVal($name, "station", "") ) {
						my @row = @{$_};
						readingsBeginUpdate($hash);
						my $i = 0;
						my $v;
						foreach (@header) {
							$v = $row[$i];
							$v =~ s/^\s+|\s+$//g;
							given(lc($_)) {
								when("temp") {
									readingsBulkUpdate($hash, "temperature", "$v °C");
									break;
									}
								when("u") {
									readingsBulkUpdate($hash, "humidity", "$v %");
									break;
									}
								when("luftd") {
									readingsBulkUpdate($hash, "pressure", "$v hPa");
									break;
									}
								when("ff") {
									readingsBulkUpdate($hash, "wind", "$v km/h");
									break;
									}
								when("fx") {
									readingsBulkUpdate($hash, "wind_peak", "$v km/h");
									break;
									}
								when("dd") {
									if ($v ne '--') {
										my %wd = (N => 0, NO => 45, O => 90, SO => 135, S => 180, SW => 225, W => 270, NW => 315, '-' => '');
										readingsBulkUpdate($hash, "wind_direction", $wd{$v}. " Grad");
									}
									break;
									}
								when("rr1") {
									readingsBulkUpdate($hash, "rain", "$v l/m²");
									readingsBulkUpdate($hash, "rain_30min", $v-ReadingsVal($name, '_rr30', 0)." l/m²");
									break;
									}
								when("rr30") {
									readingsBulkUpdate($hash, "rain_30min", "$v l/m²");
									break;
									}
									when("sss") {
									readingsBulkUpdate($hash, "snow", "$v cm");
									break;
									}
							}
							readingsBulkUpdate($hash, encode('UTF-8', "_".lc($_)), encode('UTF-8', $v));
							$i++;
						}
						readingsBulkUpdate($hash, "state", "T: ".ReadingsVal($name, '_temp', '-')." H: ".ReadingsVal($name, '_u', '-')." P: ".ReadingsVal($name, '_luftd', '-')." W: ".ReadingsVal($name, '_ff', '-'));
						readingsEndUpdate($hash, 1);
					}
				}

				$sList = encode('UTF-8', join(",", @stations));

				if ($fc =~ /\s(\d{2})\.(\d{2})\.(\d{4}),\s(\d{2}):(\d{2})\s/) {
					readingsSingleUpdate($hash, 'observation_date', "$3-$2-$1 $4:$5:00", 1);
				}
			}
			$ftp->quit;
		}
	}
}

sub DWD_PollTimer($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};

	RemoveInternalTimer($hash);
	InternalTimer(gettimeofday()+$hash->{INTERVAL}, "DWD_PollTimer", $hash, 0);
	return if ( AttrVal($name, "disable", 0) > 0 );

	DWD_RetrieveData($hash, '4_U');
	#BlockingCall("_retrieveData", $hash, "_finishedData", 60, "_abortedData", $hash);
}


1;


=pod
=item device
=begin html

<a name="DWD"></a>
<h3>DWD</h3>
<ul>
	This module provides weather conditions from <a href="http://www.dwd.de/grundversorgung">GDS service</a> 
	generated by <a href="http://www.dwd.de">DWD</a> (Deutscher Wetterdienst). Current conditions are provided for the included DWD stations at 30 minutes interval by GDS.
	<br><br>
	
	<b>Prerequesits</b>
	<ul>
		<li>Module uses following additional Perl modules:<br>
			<code>Net::FTP, HTML::Entities and HTML::TableExtract</code><br>
			If not already installed in your environment, please install them using appropriate commands from your environment.</li>
		<li>Internet connection</li>
		<li>GDS FTP account (free). Register for new account at <a href="http://www.dwd.de/grundversorgung">http://www.dwd.de/grundversorgung</a></li>
	</ul>
	<br><br>
	
	<a name="DWDdefine"></a>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; DWD &lt;username&gt; &lt;password&gt; [&lt;interval&gt; [&lt;host&gt;]]</code><br>
		<br>
		Pass the <code>username</code> and <code>password</code> for your GDS account.<br>
		Optional paramater <code>interval</code> may provide custom update interval in seconds for automatic data retrieval. Default is 1800.<br>
		Optional paramater <code>host</code> may be used to overwrite default host "ftp-outgoing2.dwd.de".<br>
	</ul>
	<br><br>

	<a name="DWDset"></a>
	<b>Set</b><br>
	<ul>
		<code>set &lt;name&gt; clear</code><br>
		<br>
		Delete all _* readings<br>
		<br><br>

		<code>set &lt;name&gt; update</code><br>
		<br>
		Forces the retrieval of the weather data and station list. The next automatic retrieval is scheduled to occur <code>interval</code> seconds later.<br>
		<br><br>

		<code>set &lt;name&gt; station</code><br>
		<br>
		Select station from list. If list is empty please do update first to download list from GDS service.<br>
	</ul>
	<br><br>

	<a name="DWDget"></a>
	<b>Get</b><br>
	<ul>
		<code>get &lt;name&gt; actual</code><br>
		<br>
		Retrieve actual weather conditions for selected station and update readings. Update timer is not restarted.<br>
		<br><br>

		<code>get &lt;name&gt; summery24h</code><br>
		<br>
		Retrieve day summary data of last day for selected station and update readings. This data is not updated automatically.<br>
	</ul>
	<br><br>

	<a name="DWDattr"></a>
	<b>Attributes</b><br>
	<ul>
		<li><b>disable</b> - if set, gds will not try to connect to internet.</li>
		<li><b>station</b> - defines station for which the data is retrieved.</li>
		<li><b>passiveFTP</b> - set to 1 to use passive FTP transfer.</li>
		<li><b>proxyHost</b> - define ftp proxy hostname in format &lt;hostname&gt;:&lt;port&gt;.</li>
		<li><b>proxyType</b> - define ftp proxy type in a value 0..7 please refer to the
			<a href="http://search.cpan.org/~gbarr/libnet-1.22/Net/Config.pm#NetConfig_VALUES">FTP library documentation</a> 
			for further informations regarding firewall settings.</li>
	</ul>
</ul>

=end html

=begin html_DE

<a name="DWD"></a>
<h3>DWD</h3>
<ul>Sorry, noch keine deutsche Dokumentaion vorhanden.</ul>

=end html_DE
=cut
