##################
# Heizungsregler #
##################
# Wiregate-Plugin
# (c) 2012 Fry under the GNU Public License

# COMPILE_PLUGIN

#$plugin_info{$plugname.'_cycle'}=0; return "deaktiviert";

use POSIX qw(floor strftime);
use Math::Round qw(nearest);

my $use_short_names=1; # 1 fuer GA-Kuerzel (erstes Wort des GA-Namens), 0 fuer die "nackte" Gruppenadresse

sub groupaddress;

# Konfigfile seit dem letzten Mal geaendert?
my $conf="/etc/wiregate/plugin/generic/conf.d/$plugname"; 
$conf.='.conf' unless $conf=~s/\.pl$/.conf/;
unless(-f $conf)
{
    plugin_log($plugname, "Config err: $conf nicht gefunden.");
    exit;
}
my $configtime=24*60*60*(-M $conf);
my $config_modified = ($configtime < $plugin_info{$plugname.'_configtime'}-1);

# Aufrufgrund ermitteln
my $event=undef;
if (!$plugin_initflag) 
{ $event='restart'; } # Restart des daemons / Reboot 
elsif ($plugin_info{$plugname.'_lastsaved'} > $plugin_info{$plugname.'_last'})
{ $event='modified'; } # Plugin modifiziert
elsif (%msg) { $event='bus'; return if !$config_modified && $msg{apci} eq "A_GroupValue_Response"; } # Bustraffic
#elsif ($fh) { $event='socket'; } # Netzwerktraffic
else { $event='cycle'; } # Zyklus

# Rueckgabewert des Plugins
my $retval='';
my $anynews=0;
my $t=time();

if($event=~/restart|modified/ || $config_modified || !defined $plugin_cache{$plugname}{house}) 
{
    my %house=();   

    # Konfigurationsfile einlesen
    open CONFIG, "<$conf" || return "no config found";
    my $lines = join '',<CONFIG>;
    close CONFIG;
    eval $lines;
    return "config error: $@" if $@;

    # Cleanup, wobei persistente dyn-Variablen (zB Solltemperaturen) gerettet werden:
    my $dyn=recall_from_plugin_info(\%house);
    for my $k (grep /^$plugname\_/, keys %plugin_info)
    {
	next if $k=~/^$plugname\_last/;
	delete $plugin_info{$k};
    }
    store_to_plugin_info($dyn,\%house);

    # %house im Cache speichern, so muss nicht jedesmal das Config eingelesen werden
    $plugin_cache{$plugname}{house}=\%house;
    $plugin_cache{$plugname}{actuators}={}; # Status Stellventile
	
    # Alle Controller-GAs abonnieren
    for my $r (grep ref($house{$_}), keys %house)
    {
	next unless defined $house{$r}{control};

	$plugin_subscribe{groupaddress($house{$r}{control})}{$plugname}=1;
	$plugin_subscribe{groupaddress($house{$r}{optimize})}{$plugname}=1 if defined $house{$r}{optimize};
	$plugin_subscribe{groupaddress($house{$r}{reset})}{$plugname}=1 if defined $house{$r}{reset};
    }

    $plugin_subscribe{groupaddress($house{control_switch})}{$plugname}=1 if defined $house{control_switch};
    $plugin_subscribe{groupaddress($house{control_status})}{$plugname}=1 if defined $house{control_status};
    $plugin_info{$plugname.'_control_status'}=1 unless defined $plugin_info{$plugname.'_control_status'};

    $plugin_info{$plugname.'_configtime'}=$configtime;

    $retval.='initialisiert: '.(join ',', (grep ref($house{$_}), keys %house)).';  ';
    $event='cycle';
}

my $house=$plugin_cache{$plugname}{house};
my $dyn=recall_from_plugin_info($house); # hier stehen bspw die persistenten Solltemperaturen

#plugin_log($plugname, "event=$event");

# Zyklischer Aufruf - Regelung
if($event=~/cycle/)
{ 
    return if $plugin_info{$plugname.'_control_status'}==0;

    my $Vreq=undef;

    # Ist die Therme ueberhaupt an?
    my $heat=knx_read($house->{heating},3000);
    $heat=(defined $heat && $heat!~/^$house->{heating_off}$/i);
    $retval.="Heating is OFF" unless $heat;
    plugin_log($plugname, "Heating is OFF") unless $heat;
    
    for my $r (sort grep ref($house->{$_}), keys %{$house})
    {
	if($heat && $dyn->{$r}{mode} eq 'ON')
	{
	    # PID-Regler
	    my ($T,$T0,$U,$Vr)=PID($r,$house,$dyn); 
	    $retval.=sprintf "$r\->%.1f(%.1f)%d%% ", $T?$T:"T?", $T0, 100*$U;
	    $anynews=1;
	    $Vreq=$Vr if defined $Vr && (!defined $Vreq || $Vr>$Vreq);
	}
	elsif($heat && $dyn->{$r}{mode} eq 'OPTIMIZE')
	{
	    # Optimierung der PID-Parameter durch Ermittlung der Sprungantwort
	    $retval.="$r\->".OPTIMIZE($r,$house,$dyn,$conf); 
	    $anynews=1;
	    $Vreq=$house->{inflow_max} if defined $house->{inflow_max};    
	}
	elsif(!$heat)
	{
	    writeactuators($r,0,$house); # alle ventile AUS    
	}
	else
	{
	    writeactuators($r,0,$house); # alle ventile AUS    
	    $dyn->{$r}{mode}='OFF';
	    $retval.="$r\->OFF ";     
	}
    }
    
    if($heat && defined $Vreq)
    {
	$Vreq=$house->{inflow_max} if defined $house->{inflow_max} && $Vreq>$house->{inflow_max};
#	knx_write(groupaddress($house->{inflow_control}),$Vreq,9.001) if defined $house->{inflow_control};
	$retval.=sprintf "KNX-would-be:Vreq=%d", $Vreq;
	$anynews=1;
    }

    $retval=~s/\s*$//; # Space am Ende entfernen

    $plugin_info{$plugname.'_cycle'}=$house->{cycle}; 
}
elsif($event=~/bus/)
{
    # Aufruf durch GA
    my $ga=$msg{dst};

    # Jemand will den Heizungsregler an- oder ausschalten, oder den Schaltstatus erfahren
    if($ga eq groupaddress($house->{control_switch}))
    {
	if($msg{apci} eq 'A_GroupValue_Write')
	{
	    $plugin_info{$plugname.'_control_status'}=int($msg{value});
	    knx_write(groupaddress($house->{control_status}), $plugin_info{$plugname.'_control_status'});
	    $plugin_info{$plugname.'_cycle'}=1; # sofort zyklisch ausfuehren, um alle Ventile zu stellen
	}
	return $retval;
    }
    elsif($ga eq groupaddress($house->{control_status}))
    {
	knx_write(groupaddress($house->{control_status}), $plugin_info{$plugname.'_control_status'}, undef, 0x40) 
	    if $msg{apci} eq 'A_GroupValue_Read';;
	return $retval;
    }

    # Telegramm betrifft Wunschtemperatur (setzen oder lesen)
    # erstmal den betroffenen Raum finden
    my @controls=(sort grep ref($house->{$_}) && groupaddress($house->{$_}{control}) eq $ga, keys %{$house});
    my @optimizes=(sort grep ref($house->{$_}) && groupaddress($house->{$_}{optimize}) eq $ga, keys %{$house});
    my @resets=(sort grep ref($house->{$_}) && groupaddress($house->{$_}{reset}) eq $ga, keys %{$house});    
    
    # Unbekannte GA de-abonnieren
    unless(@controls || @optimizes || @resets)
    {
	# GA-Abonnement loeschen
	plugin_log($plugname, "received $ga -> unsubscribed (".($plugin_subscribe{$ga}{$plugname} ? "was subscribed":"was not subscribed").")");
	delete $plugin_subscribe{$ga}{$plugname};
	return;
    }

    @resets=@optimizes=() unless $msg{apci} eq 'A_GroupValue_Write' && defined $msg{value} && $msg{value}==1;

    # nun der Reihe nach auf alle angekoppelten Aktionen reagieren
    while(@controls || @optimizes || @resets)
    {
	my $r=undef;
	my $action=undef;

	if(@controls)
	{
	    $r=shift @controls;
	    $action='control';	    
	}
	elsif(@resets)
	{
	    $r=shift @resets;
	    $action='reset';
	}
	elsif(@optimizes)
	{
	    $r=shift @optimizes;
	    $action='optimize';
	}
	
	# $r ist undef falls obige Schleife fertig durchlaufen wurde
	last unless defined $r;

	# Wert des Telegramms, Modus des Reglers abholen
	my $T0=0;
	$T0 = $msg{value} if $action eq 'control' && defined $msg{value};
	my $mode=$dyn->{$r}{mode};

	# Jemand moechte einen Sollwert wissen
	if($action eq 'control' && $msg{apci} eq 'A_GroupValue_Read')
	{
	    $T0=$dyn->{$r}{T0};
	    $T0=$dyn->{$r}{T0old} if $dyn->{$r}{mode} eq 'OPTIMIZE';
	    knx_write($ga,$T0,9.001,0x40);
	    return;
	}
	
	# spezielle Temperaturwerte sind 0-15 Grad =>OFF und -1=>OPTIMIZE
	if($action eq 'reset' || ($action eq 'control' && $T0>=0 && $T0<=15))
	{
	    RESET($r,$dyn); 
	    writeactuators($r,0,$house); 
	    $dyn->{$r}{mode}='OFF';
	    $retval.="$r\->OFF";	    
	    $anynews=1;	   
	}
	elsif($action eq 'optimize' || ($action eq 'control' && $T0==-1))
	{
	    return if $dyn->{$r}{mode} eq 'OPTIMIZE'; # Entprellen
		
	    # Initialisierung der Optimierungsfunktion
	    $dyn->{$r}{mode}='OPTIMIZE';
	    $dyn->{$r}{T0old}=$dyn->{$r}{T0};
	    writeactuators($r,0,$house); 
	    my ($T,$V,$E,$R,$spread,$window)=readsensors($r,$house);

	    $retval.=sprintf "$r\->OPT", $T;
	    $anynews=1;	   
	}
	elsif($action eq 'control') # neue Wunschtemperatur
	{
	    return if $dyn->{$r}{T0} == $T0; # Entprellen

	    RESET($r,$dyn) if $mode eq 'OPTIMIZE'; # Optimierung unterbrochen
	    $dyn->{$r}{mode}='ON'; # ansonsten uebrige Werte behalten
	    $dyn->{$r}{T0}=$T0;
	    my ($T,$T0,$U,$Vr)=PID($r,$house,$dyn); 
	    $retval.=sprintf "$r\->%.1f(%.1f)%d%%", $T, $T0, 100*$U;
	    $anynews=1;	   
	}
    }
}

# Speichere Statusvariablen aller Regler
store_to_plugin_info($dyn,$house);

#return $retval eq '' ? 'Heizungsregler: nothing to do... event='.$event : $retval;

# Heizungsregler fuehrt ein separates Log
open LOG, ">>/var/log/Heizungsregler.log";
print LOG strftime("%F %X, ", localtime).$retval."\n";
close LOG;

return unless $anynews;
return if $event=~/cycle/; # nicht den Log vollknallen
return $retval;


########## Datenpersistenz - Speichern und Einlesen ###############

sub store_to_plugin_info
{
    my ($dyn,$house)=@_;

    # Alle Laufzeitvariablen im Hash %{$dyn} 
    # in das (flache) Hash plugin_info schreiben
    for my $r (grep ref($house->{$_}), keys %{$house})
    {
	# Skalare
	my @keylist=grep !/^(temps|times|Uvals)$/, keys %{$dyn->{$r}};
	my $pi=join ',', map { $_="'$_'=>'$dyn->{$r}{$_}'" } @keylist;   
	$plugin_info{$plugname.'_'.$r} = $pi;
#	plugin_log($plugname,$r."< ".$pi) if $r eq 'D2';

	# Arrays
	for my $v (qw(temps times Uvals))
	{
	    if(defined $dyn->{$r}{$v} && $#{$dyn->{$r}{$v}}>=0)
	    {
		$plugin_info{$plugname.'_'.$r.'_'.$v}=join ',', @{$dyn->{$r}{$v}};
	    }
	    elsif(exists $plugin_info{$plugname.'_'.$r.'_'.$v})
	    {
		delete $plugin_info{$plugname.'_'.$r.'_'.$v};
	    }
	}
    }
}

sub recall_from_plugin_info
{
    my $house=shift;
    my $dyn={};

    for my $r (grep ref($house->{$_}), keys %{$house})
    {
	if(defined $plugin_info{$plugname.'_'.$r})
	{
	    my $pi=$plugin_info{$plugname.'_'.$r};
#	    plugin_log($plugname,$r."> ".$pi) if $r eq 'D2';

	    while($pi=~m/\'(.*?)\'=>\'(.*?)\'/g) { $dyn->{$r}{$1}=$2; }
	}

	for my $v (qw(temps times Uvals))
	{
	    if(defined $plugin_info{$plugname.'_'.$r.'_'.$v})
	    {
		@{$dyn->{$r}{$v}}=split ',', $plugin_info{$plugname.'_'.$r.'_'.$v};
	    }
	    else
	    {
		$dyn->{$r}{$v}=[];
	    }
	}
   }

    return $dyn;
}

sub store_to_house_config
{
    my ($r,$house,$conf)=@_; # der betreffende Raum im Haus

    open CONFIG, ">>$conf";
    print CONFIG "\$house->{$r}{pid}={";
    for my $k (sort keys %{$house->{$r}{pid}})
    {
	unless($k eq 'date')
	{
	    print CONFIG sprintf "'$k'=>%f, ", $house->{$r}{pid}{$k};
	}
	else
	{
	    print CONFIG "'$k'=>'$house->{$r}{pid}{date}', " if $k eq 'date';
	}
    }
    print CONFIG "};\n";
    close CONFIG;
}

########## Kommunikation mit Sensoren und Aktoren ###############

sub readsensors
{
    my ($r,$house)=@_; # interessierender Raum
    my @substructures=();

    push @substructures, values %{$house->{$r}->{circ}} if defined $house->{$r}->{circ};
    push @substructures, $house->{$r};

    my %T=();
    my %R=();

    for my $type (qw(sensor inflow floor outflow window))
    {
	my $dpt=$type eq 'window' ? 1 : 9;

	# Alle Sensoren eines Typs im gesamten Raum einlesen
	for my $ss (@substructures)
	{
	    if(defined $ss->{$type})
	    {
		my $sensorlist=groupaddress($ss->{$type});
		$sensorlist=[$sensorlist] unless ref $sensorlist eq 'ARRAY';

		for my $s (@{$sensorlist})
		{
		    unless(defined $T{$type}{$s})
		    {
			# wir lesen mit 3000s aus dem Cache, denn die Temp-Sensoren sind sowieso auf 1wire
			# (und antworten daher nicht innerhalb der Plugin-Laufzeit).
			# Achtung: sowohl Fensterkontakte als auch Temp-Sensoren sollten zyklisch senden!
			my $stime=time();
			$T{$type}{$s}=knx_read($s,3000,$dpt); 
			$stime=time()-$stime;
			plugin_log($plugname, "knx_read $s took $stime s") if $stime>0.8;
			delete $T{$type}{$s} unless defined $T{$type}{$s} && $T{$type}{$s}!=85;
		    }
		}
	    }
	}

	# Ueber alle Sensoren mitteln, dabei wird jeder Sensor genau einmal
	# beruecksichtigt, auch wenn er in der Konfiguration mehrfach steht
	my $n=0;
	for my $k (keys %{$T{$type}})
	{   
	    if(defined $T{$type}{$k}) 
	    {
		if($type eq 'window')
		{
		    $R{$type}=1 if int($T{$type}{$k})==0;
		}
		else
		{
		    $R{$type}+=$T{$type}{$k};
		    $n++;
		}
	    }
	}
	$R{$type}/=$n if defined $R{$type} && $type ne 'window';
    }

    # Falls Fensterkontakte nicht lesbar -> Fenster als geschlossen annehmen
    $R{window}=0 unless defined $R{window};

    # Kaputten Estrichfuehler, erkennbar an zu tiefer Temperatur,  durch Luftsensor ersetzen
    $R{floor}=$R{sensor} if defined $R{floor} && defined $R{sensor} && $R{floor}<$R{sensor};

    # outflow (Ruecklauf) und floor (Estrich) nehmen wir als gleich an,
    # falls nicht beide Werte vorhanden sind. Das sollte immer noch besser
    # sein als der globale Hauswert, um danach den Spread zu berechnen.
    unless(defined $R{outflow} && defined $R{floor})
    {
	$R{outflow}=$R{floor} if defined $R{floor};
	$R{floor}=$R{outflow} if defined $R{outflow};
    }

    # Falls Vor- oder Ruecklauf nicht fuer den Raum definiert,
    # nehmen wir die Hauswerte - falls diese verfuegbar sind
    for my $type (qw(inflow outflow))
    {
	if(!defined $R{$type} && defined $house->{$type})
	{
	    my $stime=time();
	    $R{$type} = knx_read(groupaddress($house->{$type}),3000,9);
	    $stime=time()-$stime;
	    plugin_log($plugname, "knx_read $house->{$type} took $stime s") if $stime>0.8;

	    delete $R{$type} unless $R{$type};
	}
    }

    # Jetzt Spread (Spreizung) berechnen, falls alle Daten verfuegbar
    if(defined $R{inflow} && defined $R{outflow})
    {
       $R{spread}=$R{inflow}-$R{outflow};
    }

    # und wenn alle Stricke reissen, bleibt der vorkonfigurierte Wert
    $R{spread}=$house->{spread} unless defined $R{spread};

#    plugin_log($plugname, $r.": ".(join " ", map "$_=$R{$_}", qw(sensor inflow floor outflow spread window)));

    return @R{qw(sensor inflow floor outflow spread window)};
}

sub writeactuators
{
    my ($r,$U,$house)=@_; # Raum mit Substruktur

    my @substructures=();
    @substructures=values %{$house->{$r}->{circ}} if defined $house->{$r}->{circ};
    push @substructures, $house->{$r};

    for my $ss (@substructures)
    {
	if(defined $ss->{actuator})
	{
	    $ss->{actuator}=[$ss->{actuator}] unless ref $ss->{actuator} eq 'ARRAY';

	    for my $s (@{$ss->{actuator}})
	    {
		knx_write(groupaddress($s),100*$U,5.001);
		update_rrd($s,'',100*$U) if $house->{rrd};		
		$plugin_cache{$plugname}{actuators}{$s}=100*$U;
	    }
	}
    }
}

########## PID-Regler #####################

sub RESET
{
    my ($r,$dyn)=@_; # zu regelnder Raum im Haus
    
    $dyn->{$r} = {
	mode=>'OFF', T0=>15, Told=>0, told=>$t, IS=>0, DF=>0, 
	temps=>[], times=>[], Uvals=>[], U=>0
	};
}

sub PID
{
    my ($r,$house,$dyn)=@_; # zu regelnder Raum im Haus
    my ($T,$V,$E,$R,$spread,$window)=readsensors($r,$house);

    # Ohne Temperaturmessung und Spread keine Regelung -> aufgeben
    my ($mode,$T0,$Told,$told,$IS,$DF,$temps,$times,$Uvals,$U) 
	= @{$dyn->{$r}}{qw(mode T0 Told told IS DF temps times Uvals U)};
 
    return ($T,$T0,$U,0) unless $T && $spread; 

    # Regelparameter einlesen
    my ($Tv,$Tn,$lim,$prop,$refspread)=(30,30,1,1,10); # Defaults

    if(defined $house->{$r}{pid})
    {
	($Tv,$Tn,$lim,$prop,$refspread)=@{$house->{$r}{pid}}{qw(Tv Tn lim prop refspread)};
    }
    else
    {
	$Tv=$house->{Tv} if defined $house->{Tv};
	$Tn=$house->{Tn} if defined $house->{Tn};
	$lim=$house->{lim} if defined $house->{lim};
	$prop=$house->{prop} if defined $house->{prop};
	$refspread=$house->{refspread} if defined $house->{refspread};
    }

    $Tv*=60; $Tn*=60; # in Sekunden umrechnen

    # Anzahl Datenpunkte fuer Steigungsberechnung
    my $S1=12; $S1=$house->{mindata} if defined $house->{mindata};
 
    # Anzahl Datenpunkte fuer Ermittlung neuer Vorhaltetemperatur 
    my $S2=$S1;

    push @{$temps},$T; shift @{$temps} while @{$temps}>$S1;
    push @{$times},$t; shift @{$times} while @{$times}>$S1;

    if($window)
    {
	$U=0; # Heizung aus falls Fenster offen	
	push @{$Uvals}, $U; shift @{$Uvals} while @{$Uvals}>$S2;	

	$dyn->{$r} = {
	    mode=>$mode, T0=>$T0, Told=>$T, told=>$t, IS=>$IS, DF=>$DF, 
	    temps=>$temps, times=>$times, Uvals=>$Uvals, U=>$U
	};

#	plugin_log($plugname, "$r: WINDOW");
	
	writeactuators($r,$U,$house); 
	return ($T,$T0,$U,0); 
    }

    # Skalierung fuer aktuellen Spread, Regelung wird aggressiver wenn Spread<1
    my $coeff = $spread>1 ? $refspread/($spread*$prop) : 100;
    $coeff = 100 if $coeff<0;
    $coeff = 1 if $coeff<1;

    # Proportionalteil (P)
    my $P = $T0 - $T;
    
    # Integralteil (I)
    $IS += $P * ($t - $told) / $Tn;
    
    # kein negativer I-Anteil bei reiner Heizung (nur fuer Klimaanlage erforderlich)
    $IS=0 if $IS<0; 

    # Begrenzung des I-Anteils zur Vermeidung von Ueberschwingern ("wind-up")
    $IS=+$lim/$coeff if $IS>+$lim/$coeff;
    
    # Differentialteil (D) - gemittelt wegen moeglichem Sensorrauschen
    $S1=scalar(@{$times});
    if($S1>=2)
    {
	my ($SX,$SX2,$SY,$SXY)=(0,0,0,0);
	for my $i (0..$S1-1)
	{
	    my $time=$times->[$i]-$times->[0];
	    $SX+=$time;
	    $SX2+=$time*$time;
	    $SY+=$temps->[$i];
	    $SXY+=$time*$temps->[$i];
	}
	$DF = - $Tv * ($S1*$SXY - $SX*$SY)/($S1*$SX2 - $SX*$SX);
    }
# Fuer den Fall S1==2 fuehrt die obige Regression zum gleichen Ergebnis wie:
#    $DF = - $Tv * ($T - $Told) / ($t - $told);
   
    # und alles zusammen, skaliert mit der aktuellen Spreizung
    $U = ($P + $IS + $DF) * $coeff;

    if($r eq 'WZ')
    {
	open LOG, ">>/var/log/Heizungsregler.log";
	print LOG strftime("%F %X, ", localtime).sprintf("$r: %.1f(%.1f) U = P+I+D = %d%%+%d%%+%d%% = %d%%",$T,$T0,100*$P*$coeff,100*$IS*$coeff,100*$DF*$coeff,100*$U)."\n";
	print LOG strftime("%F %X, ", localtime).sprintf("$r: coeff = %f, refspread = %f, prop = %f, spread = %f",$coeff,$refspread,$prop,$spread)."\n";
	close LOG;
    }
    
    # Stellwert begrenzen auf 0-1
    $U=1 if $U>1; 
    $U=0 if $U<0;
    push @{$Uvals}, $U; shift @{$Uvals} while @{$Uvals}>$S2;	

    # Wunsch-Vorlauftemperatur ermitteln
    my $Vr=$V;
    if(defined $Vr)
    {
	$Vr=$T0+3 if $Vr<$T0+3; # mindestens Raumwunschtemperatur + 3 Grad
	my $Uavg=0; $Uavg+=$_ foreach (@{$Uvals}); $Uavg/=scalar(@{$Uvals});

	$Vr+=1 if $Uavg>0.9;
	$Vr-=1 if $Uavg<0.6 && $V>$T0+6 && $spread>6 || $Uavg<0.75 && $V>$T0+5 && $spread>5
   	       || $Uavg<0.7 && $V>$T0+4 && $spread>4 || $Uavg<0.6 && $V>$T0+3 && $spread>3;

#	plugin_log($plugname, "room=$r, Uavg = $Uavg, T0=$T0, V=$V, spread=$spread, Vr=$Vr");
    }

    # Variablen zurueckschreiben
    $dyn->{$r} = {
	mode=>$mode, T0=>$T0, Told=>$T, told=>$t, IS=>$IS, DF=>$DF, 
	temps=>$temps, times=>$times, Uvals=>$Uvals, U=>$U
    };
    
    # Ventil einstellen 
    writeactuators($r,$U,$house); 
    
    # Ist, Soll, Stellwert, Spread, Wunsch-Vorlauftemp.
    return ($T,$T0,$U,$Vr); 
}

########## Optimierungsroutine #####################

sub OPTIMIZE
{
    my ($r,$house,$dyn,$conf)=@_;
    my ($T,$V,$E,$R,$spread,$window)=readsensors($r,$house);

    # Ohne Temperaturmessung und Spread keine Regelung -> aufgeben
    return "(OPT) " unless defined $T && defined $spread; 

    # Praktische Abkuerzungen fuer Statusvariablen
    my ($mode,$phase,$T0old) = @{$dyn->{$r}}{qw(mode phase T0old)};

#    plugin_log($plugname, "$r: phase=$phase");

    # Falls Fenster offen  -> Abbruch, Heizung aus und Regler resetten
    if($window)
    {
	if($phase ne 'COOL')
	{
	    RESET($r,$dyn);
	    $dyn->{$r}{mode}='ON'; 
	    $dyn->{$r}{T0}=$T0old;
	    return "FAILED:WINDOW ";
	}
	else
	{
	    # Tn, Tv, prop und refspread wurden am Ende der HEAT-Periode bereits berechnet.
	    # Wir nutzen die "cooling"-Periode sowieso nicht fuer die Berechnung der Parameter.
	    # Also Parameter jetzt (Beginn "cooling") schon ins Konfig-File schreiben.
	    my ($Tn, $Tv, $prop, $refspread) = @{$dyn->{$r}}{qw(Tn Tv prop refspread)};
	    my $date=strftime("%F %X",localtime);
	    my $lim=0.5; 
	    $house->{$r}{pid}={Tv=>$Tv, Tn=>$Tn, lim=>$lim, prop=>$prop, refspread=>$refspread, date=>$date};
	    store_to_house_config($r,$house,$conf);
	}
    }

    # Warte bis Therme voll aufgeheizt
    # das Aufheizen der Therme geschieht in der Hauptschleife
    $phase='WAIT' unless defined $phase;

    if($phase eq 'WAIT')
    {
	if(defined $V && defined $house->{inflow_max} && $V<$house->{inflow_max}-3)
	{
	    writeactuators($r,0,$house); # noch nicht heizen
	    return "WAIT(V=$V) "; 
	}
	
        # Falls Heizung noch nicht voll an, jetzt starten
	writeactuators($r,1,$house); # maximal heizen

	# Temperaturaufzeichnung beginnen
	$dyn->{$r} = {
	    mode=>$mode, phase=>'HEAT', 
	    T0old=>$T0old, told=>0, optstart=>$t, 
	    maxpos=>0, maxslope=>0, 
	    sumspread=>$spread, temps=>[$T], times=>[0]
	};
	
	return sprintf("%.1f(HEAT)%.1f ",$T,$spread);
    }

    my ($optstart, $sumspread, $told, $temps, $times) = @{$dyn->{$r}}{qw(optstart sumspread told temps times)};

    my $tp=$t-$optstart;

    # falls aus irgendeinem Grund zu frueh aufgerufen, tu nichts
    return sprintf("%.1f(", $T).'SKP'.sprintf(")%.1f ",$spread) 
	if $tp-$told<$house->{cycle}/2;

    # Temperaturkurve aufzeichnen
    push @{$times}, $tp; 
    push @{$temps}, $T; 
    $sumspread+=$spread;

    # Anzahl Datenpunkte fuer Steigungsberechnung. Hier verdoppelt, weil wir
    # mehr Praezision brauchen.
    my $S1=25; $S1=2*$house->{mindata} if defined $house->{mindata}; 
    
    if(scalar(@{$temps})<=$S1)
    {
	$dyn->{$r} = {
	    mode=>$mode, phase=>$phase, 
	    T0old=>$T0old, told=>$tp, optstart=>$optstart, 
	    maxpos=>0, maxslope=>0, 
	    sumspread=>$sumspread, temps=>$temps, times=>$times
	};

	return sprintf("%.1f(", $T).'OPT'.sprintf(")%.1f ",$spread);
    }

    # Steigung der Temperaturkurve durch Regression bestimmen
    my ($SX,$SY,$SY2,$SXY)=(0,0,0,0);
    
    for my $i (-$S1..-1)
    {
	$SX+=$temps->[$i];
	$SY+=$times->[$i];
	$SY2+=$times->[$i]*$times->[$i];
	$SXY+=$times->[$i]*$temps->[$i];
    }
    
    my $slope = ($S1*$SXY - $SX*$SY)/($S1*$SY2 - $SY*$SY) * 3600;
    
    if($phase eq 'HEAT')
    {
	my ($maxpos, $maxslope) = @{$dyn->{$r}}{qw(maxpos maxslope)};

#	plugin_log($plugname, "D2: maxpos=$maxpos maxslope=$maxslope slope=$slope") if $r eq 'D2';
	
#	if($maxslope==0) { $maxslope=0.005; }
	
	if($slope<=0 || $maxslope<=0.01 || $slope>=0.6*$maxslope)
	{
	    my $retval='';
	    
	    if($slope>$maxslope)
	    {
		$maxslope = $slope; 
		$maxpos = nearest(1,$#{$temps}-$S1/2);
		$retval=sprintf "%.2fKph/max=%.2fKph)",$slope,$maxslope;
	    }
	    elsif($slope>0 && $maxslope>0.01)
	    {
		$retval=sprintf "%.2fKph=%d%%", $slope, 100*$slope/$maxslope;
	    }
	    else
	    {
		$retval=sprintf "%.2fKph/max=%.2fKph)",$slope,$maxslope;
	    }
	    
	    # Statusvariablen zurueckschreiben
	    $dyn->{$r} = {
		mode=>$mode, phase=>'HEAT', 
		T0old=>$T0old, told=>$tp, optstart=>$optstart, 
		maxpos=>$maxpos, maxslope=>$maxslope, 
		sumspread=>$sumspread, temps=>$temps, times=>$times
	    };
	    
	    return sprintf("%.1f(", $T).$retval.sprintf(")%.1f ",$spread);
	}

	# Erwaermung deutlich verlangsamt -> Optimierung berechnen
	# Abschaetzung des finalen Plateauniveaus durch Annahme 
	# exponentieller Thermalisierung    
 	
        # Position maximaler Steigung
	my $pos1 = nearest(1,$maxpos-$S1/2);
	my $t1 = $times->[$maxpos];
	
	# Endpunkt
	my $t3 = $times->[nearest(1,-1-$S1/2)];
	
	# Punkt in der Mitte zwischen max. Steigung und Endpunkt
	my $pos2 = undef;
	for my $p ($maxpos..$#{$times})
	{
	    if($times->[$p]>=($t1+$t3)/2) { $pos2=$p; last; }
	}
	unless(defined $pos2)
	{
	    RESET($r,$dyn);
	    $dyn->{$r}{mode}='ON'; # ansonsten uebrige Werte behalten
	    $dyn->{$r}{T0}=$T0old;
	    return "FAILED:POS2 ";
	} 
	$pos2 = nearest(1,$pos2-$S1/2);	
	
	# Temperaturen an den Punkten t=0, maxtime, (maxtime+t)/2, t
	# gemittelt ueber S1 Werte
	my ($X0,$X1,$X2,$X3)=(0,0,0,0);
	for my $i (0..($S1-1))
	{
	    $X0+=$temps->[$i];
	    $X1+=$temps->[$i+$pos1];
	    $X2+=$temps->[$i+$pos2];
	    $X3+=$temps->[-$i-1];
	}
	$X0/=$S1; $X1/=$S1; $X2/=$S1; $X3/=$S1;  

	# Berechnung des Plateauwertes bei exponentieller Thermalisierung
	my $Xplateau=($X1*$X3 - $X2*$X2)/($X1 - 2*$X2 + $X3);

	# Analyse der Sprungantwort
	my $refspread = $sumspread/scalar(@{$times});
	my $DX = $Xplateau - $X0; 
	my $Ks = $DX/$refspread; 
	my $Tu = $t1 - 2*($tp-$told) - 3600*($X1-$X0)/$maxslope; 
	my $Tg = 3600*$DX/$maxslope;
	
	# Optimierung der PID-Parameter nach Chien/Hrones/Reswick
	# (siehe zB Wikipedia). Wir nehmen aber etwas andere Koeffizienten, 
	# das fuehrt zu ruhigerem Regelverhalten...
	
	# Proportionalbereich prop=1/Kp, kleineres prop ist aggressiver
	my $prop = $maxslope*$Tu/(0.3*$refspread)/3600; 
	
	# Nachstellzeit des Integralteils, kleiner ist aggressiver
	my $Tn = $Tg/60; 
	
	# Vorhaltezeit des Differentialteils, groesser ist aggressiver
	my $Tv = $Tu/60; 

	# alle drei Parameter muessen positiv sein, sonst Fehler
	unless($prop>=0 && $Tn>=0 && $Tv>=0)
	{
	    RESET($r,$dyn);
	    $dyn->{$r}{mode}='ON';
	    $dyn->{$r}{T0}=$T0old;
	    $dyn->{$r}{Told}=$T;
	    
	    return "FAILED:NEG ";
	}

	# Statusvariablen zurueckschreiben
	$dyn->{$r} = {
	    mode=>$mode, phase=>'COOL', 
	    T0old=>$T0old, told=>$tp, optstart=>$optstart, 
	    Tn=>$Tn, Tv=>$Tv, prop=>$prop, refspread=>$refspread, tcool=>$t3,
	    sumspread=>$sumspread, temps=>$temps, times=>$times
	};
	
	# Abkuehlung einleiten
	writeactuators($r,0,$house);
	
	return sprintf("%.1f(COOL) ",$T);
    }
    
    if($phase eq 'COOL' && $slope>0)
    {
	return sprintf("%.1f(%.2fKph) ",$T,$slope*60*60);
    }

    # Abspeichern der optimierten Parameter im Konfigurationsfile
    # aus der Laenge der "cooling"-Periode bis zum Maximum koennte man noch was berechnen, 
    # aber wir setzen $lim hier als Konstante
    my ($Tn, $Tv, $prop, $refspread, $tcool)
	= @{$dyn->{$r}}{qw(Tn Tv prop refspread tcool)};
    my $date=strftime("%F %X",localtime);
    my $lim=0.5; 
    $house->{$r}{pid}={Tv=>$Tv, Tn=>$Tn, lim=>$lim, prop=>$prop, refspread=>$refspread, date=>$date};
    store_to_house_config($r,$house,$conf);

    # Regelung starten
    RESET($r,$dyn);
    $dyn->{$r}{mode}='ON';
    $dyn->{$r}{T0}=$T0old;
    $dyn->{$r}{Told}=$T;

    # Info an den User
    return sprintf "t=%dh:%02dmin Tv=%.1fmin Tn=%dmin lim=%.1f prop=%.1f spread=%.1f ", $tp/3600,($tp/60)%60,$Tv,$Tn,$lim,$prop,$refspread;
}	    


# Umgang mit GA-Kurznamen und -Adressen

sub groupaddress
{
    my $short=shift;

    return undef unless defined $short;

    if(ref $short)
    {
	my $ga=[];
	for my $sh (@{$short})
	{
	    if($sh!~/^[0-9\/]+$/ && defined $eibgaconf{$sh}{ga})
	    {
		push @{$ga}, $eibgaconf{$sh}{ga};
	    }
	    else
	    {
		push @{$ga}, $sh;
	    }
	}
        return $ga;
    }
    else
    {
	my $ga=$short;

	if($short!~/^[0-9\/]+$/ && defined $eibgaconf{$short}{ga})
	{
	    $ga=$eibgaconf{$short}{ga};
	}

	return $ga;
    }
}

