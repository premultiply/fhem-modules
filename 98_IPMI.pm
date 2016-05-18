# $Id: 98_IPMI.pm 8728 2015-06-28 22:25:01Z premultiply $
####################################################################################################
#
#   98_IPMI.pm
#
#   An FHEM Perl module to retrieve data from an APC uninterruptible power supply (UPS) via IPMI.
#
#   Copyright: premultiply
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


package main;

use strict;
use warnings;

my $ipmipower = "/usr/sbin/ipmipower";
my $ipmisensors = "/usr/sbin/ipmi-sensors";


sub IPMI_Initialize($) {
  my ($hash) = @_;

  #$hash->{internals}{interfaces}= "temperature:battery";

  $hash->{SetFn}    = "IPMI_Set";
  $hash->{GetFn}    = "IPMI_Get";
  $hash->{DefFn}    = "IPMI_Define";
  $hash->{UndefFn}  = "IPMI_Undef";

  $hash->{AttrList} = "disable:0,1 asReadings ".$readingFnAttributes;
}


sub IPMI_Set($@) {
  my ($hash, @a) = @_;

  return "no set value specified" if(int(@a) < 2);
  
  return "on:noArg off:noArg powercycle:noArg shutdown:noArg reset:noArg on-if-off:noArg" if($a[1] eq "?");

  Log3 $hash, 0, "IPMI $hash->{NAME} Set: ".$a[1];

  return undef;
}


sub IPMI_Get($@) {
  my ($hash, @a) = @_;

  my ($cmd, $val);

  return "no get value specified" if(int(@a) != 2);
  return "Unknown argument ".$a[1].", choose one of powerstate:noArg" if($a[1] eq "?");

  $cmd = $ipmipower.(defined $hash->{HOST} ? " -h ".$hash->{HOST} : "").
           (defined $hash->{USERNAME} ? " -u ".$hash->{USERNAME} : "").
           (defined $hash->{PASSWORD} ? " -p ".$hash->{PASSWORD} : "").
           " -s --session-timeout=1000 --always-prefix 2>&1";
  $val = `$cmd`;

  if ( $val =~ m/connection timeout/ | ! length($val) ) {
    Log3 $hash, 1, $val;
    readingsSingleUpdate($hash, 'state', 'ERROR', 1);
    return $val;
  }

  if ( $val =~ m/^(.+?):\s*(.+?)$/ ) {
    readingsSingleUpdate($hash, 'state', $2, 1);
    return $2;
  }

  return $val;
}


sub IPMI_Define($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  return "Usage: define <name> IPMI [<host> [<user> [<password> [<interval>]]]]"  if ( @a < 2 or @a > 6 );

  if ( ! -e $ipmipower ) {
    return "ERROR: $ipmipower does not exist. Please install freeipmi-tools.";
  }
  if ( ! -x $ipmipower ) {
    return "ERROR: $ipmipower is not executable.";
  }
  if ( ! -e $ipmisensors ) {
    return "ERROR: $ipmisensors does not exist. Please install freeipmi-tools.";
  }
  if ( ! -x $ipmisensors ) {
    return "ERROR: $ipmisensors is not executable.";
  }

  my $name = $a[0];

  my $interval = 60;
  if ( int(@a)>=6 ) { $interval = $a[5]; }
  if ( $interval < 10 ) { $interval = 10; }

  $hash->{HOST} = $a[2];
  $hash->{USERNAME} = $a[3];
  $hash->{PASSWORD} = $a[4];
  $hash->{STATE} = "Initialized";
  $hash->{INTERVAL} = $interval;

  IPMI_PollTimer($hash);

  return undef;
}


sub IPMI_Undef($$) {
  my ($hash, $arg) = @_;

  RemoveInternalTimer($hash);
  return undef;
}


sub IPMI_RetrieveData($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my ($cmd, $val);

#POWER

  $cmd = $ipmipower.(defined $hash->{HOST} ? " -h ".$hash->{HOST} : "").
           (defined $hash->{USERNAME} ? " -u ".$hash->{USERNAME} : "").
           (defined $hash->{PASSWORD} ? " -p ".$hash->{PASSWORD} : "").
           " -s --session-timeout=1000 --always-prefix 2>&1";
  $val = `$cmd`;

  if ( $val =~ m/connection timeout/ | ! length($val) ) {
    Log3 $hash, 1, $val;
    readingsSingleUpdate($hash, 'state', 'ERROR', 1);
    return $val;
  }

  if ( $val =~ m/^(.+?):\s*(.+?)$/ ) {
    readingsSingleUpdate($hash, 'state', $2, 1);
  }

#SENORS

  $cmd = $ipmisensors.(defined $hash->{HOST} ? " -h ".$hash->{HOST} : "").
           (defined $hash->{USERNAME} ? " -u ".$hash->{USERNAME} : "").
           (defined $hash->{PASSWORD} ? " -p ".$hash->{PASSWORD} : "").
           " -Q --interpret-oem-data --comma-separated-output --no-header-output --ignore-unrecognized-events --ignore-not-available-sensors --session-timeout=5000 2>&1";
  $val = `$cmd`;

  if ( $val =~ m/connection timeout/ | ! length($val) ) {
    Log3 $hash, 1, $val;
    readingsSingleUpdate($hash, 'state', 'ERROR', 1);
    return $val;
  }

  my @lines = split /\n/, $val;

  no warnings 'numeric';

  foreach my $line (@lines) {
    my @values = split /,/, $line;
    $values[1] =~ s/\s+//;
    $values[2] =~ s/\s+//;
    $values[3] =~ s/\s+//;
    $hash->{helper}{lc($values[2]).$values[1]} = $values[3];
  }

  readingsBeginUpdate($hash);
  foreach (split (',', $attr{$name}{asReadings})) {
    s/^\s+//;
    s/\s+$//;
    $hash->{helper}{$_} =~ m/^([\-\d\.]*)(.*)$/;
    if ( length($1) > 0 ) {
      readingsBulkUpdate($hash, $_, 0+$1) if defined $hash->{helper}{$_};
    } else {
      readingsBulkUpdate($hash, $_, $2) if defined $hash->{helper}{$_};
    }
  }
  readingsEndUpdate($hash, 1);
  
  return undef;
}


sub IPMI_PollTimer($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday()+$hash->{INTERVAL}, "IPMI_PollTimer", $hash, 0);
  return if ( AttrVal($name, "disable", 0) > 0 );

  IPMI_RetrieveData($hash);
}


1;

=pod
=begin html

<a name="IPMI"></a>
<h3>IPMI</h3>
<ul>
  FreeIPMI (<a href="https://www.gnu.org/software/freeipmi/">https://www.gnu.org/software/freeipmi/</a>) provides in-band and out-of-band system management based on the IPMI v1.5/2.0 specification. The IPMI specification defines a set of interfaces for platform management and is implemented by a number vendors for system management.<br>

  <br><br>

  <a name=IPMIdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;devicename&gt; IPMI [&lt;intervall&gt; [&lt;host&gt;]</code><br>
    <br>
    &lt;intervall&gt; is the interval of data queries to IPMI. Default is <code>60</code> seconds.<br>
    &lt;host&gt; is the hostname or IP address of the IPMI server. Default is <code>localhost</code>.<br>
    <br>
    For the function of this module a local installation of freeipmi-tools package is required. The ipmipower tool is used for data access and control.<br>
    <br>
    If multiple UPS systems are connected to a single host multiple IPMI instances on different TCP ports have to be configured there.<br>
    To set up such a "multiple UPS system" please note <a href="http://www.IPMI.com/manual/manual.html#controlling-multiple-upses-on-one-machine">www.IPMI.com/manual/manual.html#controlling-multiple-upses-on-one-machine</a>.<br>
    <br><br>
    Examples: <br>
    <code>define Server1 IPMI</code><br>
    <code>define Server2 IPMI 60 192.168.0.100:3551</code><br>
  </ul>
  <br>

  <a name="IPMIattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#disable">disable</a></li><br>
    <li><a name="IPMI_asReadings">asReadings</a><br>
        Comma-separated list of UPS values ​​to be used as readings. Default is <code>BATTV,BCHARGE,LINEV,LOADPCT,OUTPUTV,TIMELEFT,LASTXFER</code>.<br>
        Available values ​​can be listed using <code>list &lt;devicename&gt;</code>.<br>
        All availible readings for specific UPS model are listed in the section following "Helper:".<br>
        Example:<br>
        <code>attr &lt;name&gt; asReadings TONBATT,NUMXFERS,LINEFREQ</code></li><br>
  </ul>

  <a name="IPMIreadings"></a>
  <b>Readings</b>
  <ul>
    <li><a href="IPMI_battery">battery</a><br>
    Battery level of the UPS. "ok" if > 20%, else "low" (if availible)</li><br>
    <li><a href="IPMI_state">state</a><br>
    The state of the UPS (ONLINE, ON BATTERY, ...)</li><br>
    <li><a href="IPMI_temperature">temperature</a><br>
    Internal system temperature (if availible) in degrees Celsius</li><br>
    <li>and the configured parameters by asReadings</li><br>
  </ul>
</ul>

=end html

=begin html_DE

<a name="IPMI"></a>
<h3>IPMI</h3>
<ul>
  IPMI (<a href="http://www.IPMI.com/">www.IPMI.com</a>) bietet Unterstützung für unterbrechungsfreie Stromversorgungen (USV) von APC. Dieses Modul ermöglicht den Zugriff auf einen IPMI-Server, womit man Daten auslesen kann (z.B. den Status, Restlaufzeit, Eingangsspannung, Temperatur usw.).<br>

  <br><br>

  <a name=IPMIdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;devicename&gt; IPMI [&lt;intervall&gt; [&lt;host&gt;[:&lt;port&gt;]]</code><br>
    <br>
    &lt;intervall&gt; ist das Poll-Intervall mit dem Daten von IPMI abgefragt werden. Default ist <code>60</code> Sekunden.<br>
    &lt;host&gt; ist der Hostname oder die IP-Adresse des IPMI-Servers. Default ist <code>localhost</code>.<br>
    :&lt;port&gt; ist der TCP-Port auf den die IPMI-Instanz konfiguriert wurde. Default ist <code>:3551</code>.<br>
    <br>
    Für die Funktion dieses Moduls wird eine lokale Installation des IPMI-Pakets benötigt da das darin enthaltene apcaccess-Tool für den Datenzugriff genutzt wird.
    Der ebenfalls enthaltene IPMI-Dienst muss hingegen nicht zwingend auf dem FHEM-System laufen.
    Der Netzwerkzugriff auf externe IPMI-Hosts ist möglich. Ebenso ein lokaler und vernetzter Mischbetrieb.<br>
    <br>
    Sollen mehrere USV-Systeme an einem Host von IPMI überwacht werden sind dort mehrere IPMI-Instanzen auf verschiedenen TCP-Ports notwendig.<br>
    Zur Einrichtung eines solchen "Mehrfach-USV-Systems" bitte <a href="http://www.IPMI.com/manual/manual.html#controlling-multiple-upses-on-one-machine">www.IPMI.com/manual/manual.html#controlling-multiple-upses-on-one-machine</a> beachten.<br>
    <br><br>
    Beispiele: <br>
    <code>define Usv1 IPMI</code><br>
    <code>define Usv2 IPMI 60 localhost:3552</code><br>
    <code>define Usv3 IPMI 60 192.168.0.100:3551</code><br>
  </ul>
  <br>

  <a name="IPMIattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#disable">disable</a></li><br>
    <li><a name="IPMI_asReadings">asReadings</a><br>
        Mit Kommata getrennte Liste der USV-Werte, die als Readings verwendet werden sollen. Der Standardwert lautet <code>BATTV,BCHARGE,LINEV,LOADPCT,OUTPUTV,TIMELEFT,LASTXFER</code>.<br>
        Verfügbare Werte lassen sich mittels <code>list &lt;devicename&gt;</code> darstellen.<br>
        Die vom jeweiligen USV-Modell auslesbaren Parameter werden dort im Abschnitt "Helper:" gelistet.<br>
        Beispiel:<br>
        <code>attr &lt;name&gt; asReadings TONBATT,NUMXFERS,LINEFREQ</code></li><br>
  </ul>

  <a name="IPMIreadings"></a>
  <b>Readings</b>
  <ul>
    <li><a href="IPMI_battery">battery</a><br>
    Akkuladestand der USV. "ok" wenn > 20%, sonst "low" (wenn verfügbar)</li><br>
    <li><a href="IPMI_state">state</a><br>
    Der Zustand der USV (ONLINE, ON BATTERY, ...)</li><br>
    <li><a href="IPMI_temperature">temperature</a><br>
    Interne Systemtemperatur (wenn verfügbar) in Grad Celsius</li><br>
    <li>sowie die unter asReadings konfigurierten Parameter</li><br>
  </ul>
</ul>

=end html_DE
=cut

