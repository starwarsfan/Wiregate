# Monitoring a PV system with Kaco ProLOG
# v0.2
# License: GPL v2

use LWP::Simple;
use HTML::TableExtract; # get it with 'apt-get install libhtml-tableextract-perl'

# Configuration 
# ****************************

my $myProLogIP          = "192.168.178.116";	# IP address of Kaco ProLOG
my $myCurrentPowerGA    = "0/4/236";		# GA for sending current power [W], DPT 14.056
my $myEnergyTodayGA     = "0/4/233";		# GA for sending energy produced this day [Wh], DPT 13.010
my $myEneryYesterdayGA  = "";
my $myEnergyThisMonthGA = "0/4/234";		# GA for sending energy produced this month [kWh], DPT 13.013
my $myEnergyThisYearGA  = "0/4/235";		# GA for sending energy produced this year [Wh], DPT 13.013
my $myEnergyTotalGA     = "0/4/230";		# GA for sending total accumulated enery production [kWh], DPT 13.013
# ToDo
my $myEnergy15minGA     = "0/4/231";		# GA for sending energy produced in last 15min [Wh], DPT 13.010
my $myEnergy60minGA     = "0/4/232";		# GA for sending energy produced in last 60min [Wh], DPT 13.010


# Arrays to hold GAs for detailed values from the single power converters
# Use their RS485 bus address as array index
# If a GA is left empty, it is not send to the bus
my @myDcVoltageGA; 		# DC voltage in [V], DPT 14.027
my @myDcCurrentGA;		# DC current in [A], DPT 14.019
my @myDcPowerGA;		# DC power [W], DPT 13.010
my @myAcVoltageGA;		# AC voltage in [V], DPT 14.027
my @myAcCurrentGA;		# AC current in [A], DPT 14.019
my @myAcPowerGA;		# AC power in [W], DPT 13.010
my @myAcDailyEnergyGA;		# Energy output, daily accumulation in [kWh], DPT 13.013
my @myTemperatureGA;		# Temperature of inverter in [°C], DPT 9.001
my @myStatusGA;			# Status of inverter, DPT 5.010

# WR1 Powador 6002
$myDcVoltageGA[1]     = "0/4/237";
$myDcCurrentGA[1]     = "0/4/238";
$myDcPowerGA[1]       = "0/4/239";
$myAcVoltageGA[1]     = "0/4/240";
$myAcCurrentGA[1]     = "0/4/241";
$myAcPowerGA[1]       = "0/4/242";
$myAcDailyEnergyGA[1] = "0/4/243";
$myTemperatureGA[1]   = "0/4/244";
$myStatusGA[1]        = "0/4/245";
# WR2 Powador 2002
$myDcVoltageGA[2]     = "0/4/246";
$myDcCurrentGA[2]     = "0/4/247";
$myDcPowerGA[2]       = "0/4/248";
$myAcVoltageGA[2]     = "0/4/249";
$myAcCurrentGA[2]     = "0/4/250";
$myAcPowerGA[2]       = "0/4/251";
$myAcDailyEnergyGA[2] = "0/4/252";
$myTemperatureGA[2]   = "0/4/253";
$myStatusGA[2]        = "0/4/254";


# End Configuration
# *****************************
# Do not change below here

my $mySummaryDataDownloadPath = "/html/de/locale_live_standard.html";
my $myDetailedDataDownloadPath = "/get_online_wr.cgi?q=U_DC_0;I_DC_0;P_DC_WR;U_AC_0;I_AC_0;P_AC_WR;T_WR;E_D_WR;S";
my $myWrOverviewPath = "/html/de/onlineOverWr.html";
my @myWRStatusMsg;

$myWRStatusMsg[ 0] = 'WR gerade eingeschaltet';
$myWRStatusMsg[ 1] = 'Warten auf Start';
$myWRStatusMsg[ 2] = 'Warten auf Ausschalten';
$myWRStatusMsg[ 3] = 'Konstantspannungsregler';
$myWRStatusMsg[ 5] = 'Einspeisung (MPP-Tracker)';
$myWRStatusMsg[ 8] = 'Selbsttest';
$myWRStatusMsg[ 9] = 'Testbetrieb';
$myWRStatusMsg[10] = 'Gerätetemperatur zu hoch';
$myWRStatusMsg[11] = 'Leistungsbegrenzung';
$myWRStatusMsg[29] = 'Erdschluss Sicherung prüfen!';
$myWRStatusMsg[30] = 'Störung Messwandler';
$myWRStatusMsg[32] = 'Fehler Selbsttest';
$myWRStatusMsg[33] = 'Fehler DC-Einspeisung';
$myWRStatusMsg[34] = 'Fehler Kommunikation';
$myWRStatusMsg[35] = 'Schutzabschaltung (SW)';
$myWRStatusMsg[36] = 'Schutzabschaltung (HW)';
$myWRStatusMsg[38] = 'Fehler PV-Überspannung';
$myWRStatusMsg[41] = 'Netzstörung Unterspannung';
$myWRStatusMsg[42] = 'Netzstörung Überspannung';
$myWRStatusMsg[48] = 'Netzstörung Unterfrequenz';
$myWRStatusMsg[49] = 'Netzstörung Überfrequenz';
$myWRStatusMsg[50] = 'Netzstörung Mittelwert Spg';
$myWRStatusMsg[51] = 'Netzstörung Überspannung L1';
$myWRStatusMsg[52] = 'Netzstörung Unterspannung L1';
$myWRStatusMsg[53] = 'Netzstörung Überspannung L2';
$myWRStatusMsg[54] = 'Netzstörung Unterspannung L2';
$myWRStatusMsg[55] = 'Fehler Zwischenkreis';
$myWRStatusMsg[57] = 'Warten auf Wiederzuschalten';
$myWRStatusMsg[58] = 'Übertemperatur Steuerkarte';
$myWRStatusMsg[59] = 'Fehler Selbsttest';
$myWRStatusMsg[60] = 'PV-Spannung zu hoch';
$myWRStatusMsg[61] = 'Power-Control';
$myWRStatusMsg[62] = 'Inselbetrieb';
$myWRStatusMsg[63] = 'Frequenzabhängige Leistungsreduzierung';
$myWRStatusMsg[64] = 'Ausgangsstrombegrenzung';
$myWRStatusMsg[''] = 'Nicht verfügbar/ausgeschaltet';

$plugin_info{$plugname.'_cycle'} = 30;

my $content = get( "http://$myProLogIP$mySummaryDataDownloadPath" );
return "Übersichts-Webabfrage fehlgeschlagen" unless defined $content;

my @myOverview = split( /\|/, $content );

# calculate W from kW
$myOverview[0] *= 1000;

knx_write( $myCurrentPowerGA , $myOverview[0], 14 );
update_rrd("PV", "P_total", $myOverview[0] );

# more detailed data are requested here
$content = get( "http://$myProLogIP$myDetailedDataDownloadPath" );
return "Detail-Webabfrage fehlgeschlagen" unless defined $content;

my @myDetails = split( /\n/, $content ); 
my $myWRStatusChanges = '';

for my $i (2 .. $#myDetails - 1) {
    $myDetails[$i] =~ s/\r//g;	# remove carrige return
    my @myWRDetails = split( /;/, $myDetails[$i] );
    
    # only process if system supplies values
    if( $myWRDetails[2] != '' ) {
        # store and send values
        update_rrd( 'PV', "DcVoltage_WR$myWRDetails[1]", $myWRDetails[2] );
        if( $myDcVoltageGA[ $myWRDetails[1] ] ) { knx_write( $myDcVoltageGA[ $myWRDetails[1] ], $myWRDetails[2], 14 ); }
        update_rrd( 'PV', "DcCurrent_WR$myWRDetails[1]", $myWRDetails[3] );
        if( $myDcCurrentGA[ $myWRDetails[1] ] ) { knx_write( $myDcCurrentGA[ $myWRDetails[1] ], $myWRDetails[3], 14 ); }
        update_rrd( 'PV', "DcPower_WR$myWRDetails[1]", $myWRDetails[4] );
        if( $myDcPowerGA[ $myWRDetails[1] ] ) { knx_write( $myDcPowerGA[ $myWRDetails[1] ], $myWRDetails[4], 13 ); }
        update_rrd( 'PV', "AcVoltage_WR$myWRDetails[1]", $myWRDetails[5] );
        if( $myAcVoltageGA[ $myWRDetails[1] ] ) { knx_write( $myAcVoltageGA[ $myWRDetails[1] ], $myWRDetails[5], 14 ); }
        update_rrd( 'PV', "AcCurrent_WR$myWRDetails[1]", $myWRDetails[6] );
        if( $myAcCurrentGA[ $myWRDetails[1] ] ) { knx_write( $myAcCurrentGA[ $myWRDetails[1] ], $myWRDetails[6], 14 ); }
        update_rrd( 'PV', "AcPower_WR$myWRDetails[1]", $myWRDetails[7] );
        if( $myAcPowerGA[ $myWRDetails[1] ] ) { knx_write( $myAcPowerGA[ $myWRDetails[1] ], $myWRDetails[7], 13 ); }
        update_rrd( 'PV', "Temperature_WR$myWRDetails[1]", $myWRDetails[8] );
        if( $myTemperatureGA[ $myWRDetails[1] ] ) { knx_write( $myTemperatureGA[ $myWRDetails[1] ], $myWRDetails[8], 9 ); }
        update_rrd( 'PV', "DailyEnergy_WR$myWRDetails[1]", $myWRDetails[9] / 1000 );
        if( $myAcDailyEnergyGA[ $myWRDetails[1] ] ) { knx_write( $myAcDailyEnergyGA[ $myWRDetails[1] ], $myWRDetails[9]/1000, 13 ); }	
        update_rrd( 'PV', "Status_WR$myWRDetails[1]", $myWRDetails[10] );
        if( $myStatusGA[ $myWRDetails[1] ] ) { knx_write( $myStatusGA[ $myWRDetails[1] ], $myWRDetails[10], 5 ); }
            
        # save last status of inverter
        if ( $myWRDetails[10] != $plugin_info{$plugname."_WRState$myWRDetails[1]"} ) {
            $myWRStatusChanges .= "WR$myWRDetails[1] Status ".$plugin_info{$plugname."_WRState$myWRDetails[1]"}." (".$myWRStatusMsg[$plugin_info{$plugname."_WRState$myWRDetails[1]"}].") -> ".$myWRDetails[10]." ($myWRStatusMsg[$myWRDetails[10]]) , ";
            $plugin_info{$plugname."_WRState$myWRDetails[1]"} = $myWRDetails[10];
        }
    }
}


$content = get( "http://$myProLogIP$myWrOverviewPath" );
return "Übersichts-Webabfrage fehlgeschlagen" unless defined $content;

my $tables = HTML::TableExtract->new( );
$tables->parse($content);

my $lastElement = "";
foreach my $table ($tables->tables) {
    foreach my $rowCols ($table->rows) {
        foreach my $col (@$rowCols) {
            if( $lastElement eq "Aktuelle Monatsenergie" ) {
                knx_write( $myEnergyThisMonthGA , $col, 13 );
            } elsif ( $lastElement eq "Aktuelle Tagesenergie" ) {
                knx_write( $myEnergyTodayGA , $col, 13 );
            } elsif ( $lastElement eq "Aktuelle Jahresenergie" ) {
                knx_write( $myEnergyThisYearGA , $col, 13 );
            } elsif ( $lastElement eq "Tagesenergie Vortag" ) {
                knx_write( $myEneryYesterdayGA , $col, 13 );
            } elsif ( $lastElement eq "Gesamtenergie" ) {
                knx_write( $myEnergyTotalGA , $col, 13 );
            }
            $lastElement = $col;
        }
    }
}


return $myWRStatusChanges;
