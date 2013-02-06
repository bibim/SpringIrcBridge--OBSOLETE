# Object-oriented Perl module implementing a callback-based interface for
# Spring lobby.
#
# Copyright (C) 2008  Yann Riou <yannriou0@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package PerlLobbyInterface;

use strict;

use IO::Socket::INET;
use Digest::MD5 "md5_base64";
use List::Util "shuffle";
use Storable "dclone";

use SimpleLog;

# Internal data ###############################################################

my $moduleVersion="0.13a";

my %sentenceStartPosClient = (
  REQUESTUPDATEFILE => 1,
  LOGIN => 5,
  CHANNELTOPIC => 2,
  FORCELEAVECHANNEL => 3,
  SAY => 2,
  SAYEX => 2,
  SAYPRIVATE => 2,
  OPENBATTLE => 9,
  UPDATEBATTLEINFO => 4,
  SAYBATTLE => 1,
  SAYBATTLEPRIVATE => 2,
  SAYBATTLEEX => 1,
  SAYBATTLEPRIVATEEX => 2,
  ADDBOT => 4,
  SCRIPT => 1,
  SETSCRIPTTAGS => 1,
  JOINBATTLEDENY => 2
);

my %sentenceStartPosServer = (
  REGISTRATIONDENIED => 1,
  DENIED => 1,
  AGREEMENT => 1,
  MOTD => 1,
  OFFERFILE => 2,
  SERVERMSG => 1,
  SERVERMSGBOX => 1,
  JOINFAILED => 2,
  MUTELIST => 1,
  CHANNELTOPIC => 4,
  CLIENTS => 2,
  LEFT => 3,
  FORCELEAVECHANNEL => 3,
  SAID => 3,
  SAIDEX => 3,
  SAYPRIVATE => 2,
  SAIDPRIVATE => 2,
  BATTLEOPENED => 11,
  JOINBATTLEFAILED => 1,
  OPENBATTLEFAILED => 1,
  UPDATEBATTLEINFO => 5,
  SAIDBATTLE => 2,
  SAIDBATTLEEX => 2,
  BROADCAST => 1,
  ADDBOT => 6,
  MAPGRADESFAILED => 1,
  SCRIPT => 1,
  SETSCRIPTTAGS => 1,
  CHANNELMESSAGE => 2,
  CHANNEL => 3
);

my @tabWorkaroundCommands = qw/CHANNELTOPIC SAID SAIDEX SAIDPRIVATE SAIDBATTLE SAIDBATTLEEX SAYPRIVATE/;

my %commandHooks = (
  LEAVE => \&leaveChannelHandler,
  OPENBATTLE => \&openBattleHook,
  JOINBATTLE => \&joinBattleHook,
  DISABLEUNITS => \&disableUnitsHandler,
  ENABLEUNITS => \&enableUnitsHandler,
  ENABLEALLUNITS => \&enableAllUnitsHandler,
  ADDSTARTRECT => \&addStartRectHandler,
  REMOVESTARTRECT => \&removeStartRectHandler
);

my %commandHandlers = (
  ACCEPTED => \&acceptedHandler,
  CLIENTIPPORT => \&clientIpPortHandler,
  JOINBATTLEREQUEST => \&joinBattleRequestHandler,
  ADDUSER => \&addUserHandler,
  REMOVEUSER => \&removeUserHandler,
  JOIN => \&joinHandler,
  CLIENTS => \&clientsHandler,
  JOINED => \&joinedHandler,
  LEFT => \&leftHandler,
  FORCELEAVECHANNEL => \&leaveChannelHandler,
  OPENBATTLE => \&openBattleHandler,
  BATTLEOPENED => \&battleOpenedHandler,
  BATTLECLOSED => \&battleClosedHandler,
  JOINBATTLE => \&joinBattleHandler,
  JOINEDBATTLE => \&joinedBattleHandler,
  LEFTBATTLE => \&leftBattleHandler,
  UPDATEBATTLEINFO => \&updateBattleInfoHandler,
  CLIENTSTATUS => \&clientStatusHandler,
  CLIENTBATTLESTATUS => \&clientBattleStatusHandler,
  DISABLEUNITS => \&disableUnitsHandler,
  ENABLEUNITS => \&enableUnitsHandler,
  ENABLEALLUNITS => \&enableAllUnitsHandler,
  ADDBOT => \&addBotHandler,
  REMOVEBOT => \&removeBotHandler,
  UPDATEBOT => \&updateBotHandler,
  ADDSTARTRECT => \&addStartRectHandler,
  REMOVESTARTRECT => \&removeStartRectHandler,
  SETSCRIPTTAGS => \&setScriptTagsHandler
);

# Constructor #################################################################

sub new {
  my ($objectOrClass,%params) = @_;
  my $class = ref($objectOrClass) || $objectOrClass;
  my $p_conf = {
    serverHost => 'lobby.springrts.com',
    serverPort => 8200,
    timeout => 30,
    simpleLog => undef,
    warnForUnhandledMessages => 1
  };
  foreach my $param (keys %params) {
    if(grep(/^$param$/,(keys %{$p_conf}))) {
      $p_conf->{$param}=$params{$param};
    }else{
      if(! (defined $p_conf->{simpleLog})) {
        $p_conf->{simpleLog}=SimpleLog->new(prefix => "[PerlLobbyInterface] ");
      }
      $p_conf->{simpleLog}->log("Ignoring invalid constructor parameter ($param)",2)
    }
  }
  if(! (defined $p_conf->{simpleLog})) {
    $p_conf->{simpleLog}=SimpleLog->new(prefix => "[PerlLobbyInterface] ");
  }

  my $self = {
    conf => $p_conf,
    lobbySock => undef,
    readBuffer => "",
    login => undef,
    users => {},
    accounts => {},
    channels => {},
    battles => {},
    battle => {},
    runningBattle => {},
    callbacks => {},
    preCallbacks => {},
    pendingRequests => {},
    pendingResponses => {},
    openBattleModHash => 0,
    password => "*"
  };

  bless ($self, $class);
  return $self;
}

# Accessors ###################################################################

sub getVersion {
  return $moduleVersion;
}

sub getLogin {
  my $self = shift;
  return $self->{login};
}

sub getUsers {
  my $self = shift;
  return dclone($self->{users});
}

sub getChannels {
  my $self = shift;
  return dclone($self->{channels});
}

sub getBattles {
  my $self = shift;
  return dclone($self->{battles});
}

sub getBattle {
  my $self = shift;
  return dclone($self->{battle});
}

sub getRunningBattle {
  my $self = shift;
  return dclone($self->{runningBattle});
}

# Debugging method ############################################################

sub dumpState {
  my $self=shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("-------------------------- DUMPING STATE ----------------------------",5);
  $sl->log("USERS:",5);
  my %users=%{$self->{users}};
  foreach my $u (keys %users) {
    my $userString="  $u (CPU:$users{$u}->{cpu},country:$users{$u}->{country}";
    foreach my $status (keys %{$users{$u}->{status}}) {
      $userString.=",$status:$users{$u}->{status}->{$status}";
    }
    $sl->log($userString.")",5);
  }
  $sl->log("CHANNELS:",5);
  my %chans=%{$self->{channels}};
  foreach my $c (keys %chans) {
    $sl->log("  $c (".join(",",keys %{$chans{$c}}).")",5);
  }
  $sl->log("BATTLES:",5);
  my %battles=%{$self->{battles}};
  foreach my $b (keys %battles) {
    my $bString="  $b (";
    my $needComa=0;
    foreach my $k (keys %{$battles{$b}}) {
      next if($k eq "userList");
      $bString.=("," x $needComa)."$k:$battles{$b}->{$k}";
      $needComa=1;
    }
    $bString.=",userList=";
    my @userList=@{$battles{$b}->{userList}};
    for my $i (0..$#userList) {
      $bString.=" $userList[$i]";
    }
    $sl->log($bString.")",5);
  }
  $sl->log("CURRENT BATTLE:",5);
  my %battle=%{$self->{battle}};
  if(%battle) {
    $sl->log("  battle ID:$battle{battleId}",5);
    $sl->log("  founder:$battle{founder}",5);
    $sl->log("  modHash:$battle{modHash}",5);
    $sl->log("  users:",5);
    foreach my $u (keys %{$battle{users}}) {
      $sl->log("    $u:",5);
      my $statusString="      battleStatus: ";
      foreach my $us (keys %{$battle{users}->{$u}->{battleStatus}}) {
        $statusString.="$us=$battle{users}->{$u}->{battleStatus}->{$us},";
      }
      $sl->log($statusString,5);
      my $colorString="      color: ";
      foreach my $col (keys %{$battle{users}->{$u}->{color}}) {
        $colorString.="$col=$battle{users}->{$u}->{color}->{$col},";
      }
      $sl->log($colorString,5);
      $sl->log("      ip:$battle{users}->{$u}->{ip}",5) if(defined $battle{users}->{$u}->{ip});
      $sl->log("      port:$battle{users}->{$u}->{port}",5) if(defined $battle{users}->{$u}->{port});
    }

    $sl->log("  bots:",5);
    foreach my $b (keys %{$battle{bots}}) {
      $sl->log("    $b:",5);
      $sl->log("      owner:$battle{bots}->{$b}->{owner}",5);
      $sl->log("      aiDll:$battle{bots}->{$b}->{aiDll}",5);
      my $statusString="     battleStatus: ";
      foreach my $bs (keys %{$battle{bots}->{$b}->{battleStatus}}) {
        $statusString.="$bs=$battle{bots}->{$b}->{battleStatus}->{$bs},";
      }
      $sl->log($statusString,5);
      my $colorString="      color: ";
      foreach my $col (keys %{$battle{bots}->{$b}->{color}}) {
        $colorString.="$col=$battle{bots}->{$b}->{color}->{$col},";
      }
      $sl->log($colorString,5);
    }
    my $disString="  disabled units:";
    foreach my $du (@{$battle{disabledUnits}}) {
      $disString.="$du,";
    }
    $sl->log($disString,5);
    $sl->log("  start rects:",5);
    foreach my $id (keys %{$battle{startRects}}) {
      my $srString="    $id: ";
      foreach my $point (keys %{$battle{startRects}->{$id}}) {
        $srString.="$point=$battle{startRects}->{$id}->{$point},";
      }
      $sl->log($srString,5);
    }
    my $stString="  script tags: ";
    foreach my $tag (keys %{$battle{scriptTags}}) {
      $stString.="$tag=$battle{scriptTags}->{$tag},";
    }
    $sl->log($stString,5);
  }
  $sl->log("-------------------------- END OF DUMP ----------------------------",5);
}

# Marshallers/unmarshallers ###################################################

sub marshallPasswd {
  my ($self,$passwd) = @_;
  return md5_base64($passwd)."==";
}

sub marshallClientStatus {
  my ($self,$p_clientStatus)=@_;
  my %cs=%{$p_clientStatus};
  return oct("0b".$cs{bot}.$cs{access}.sprintf("%03b",$cs{rank}).$cs{away}.$cs{inGame});
}

sub unmarshallClientStatus {
  my ($self,$clientStatus)=@_;
  my $csBin=sprintf("%07b",$clientStatus);
  my @cs=split("",$csBin);
  my $offset=0;
  $offset=$#cs-6 if($#cs>6);
  return { inGame => $cs[$offset+6],
           away => $cs[$offset+5],
           rank => oct("0b".$cs[$offset+2].$cs[$offset+3].$cs[$offset+4]),
           access =>$cs[$offset+1],
           bot => $cs[$offset] };
}

sub marshallBattleStatus {
  my ($self,$p_battleStatus)=@_;
  my %bs=%{$p_battleStatus};
  return oct("0b0000".sprintf("%04b",$bs{side}).sprintf("%02b",$bs{sync})."0000".sprintf("%07b",$bs{bonus}).$bs{mode}.sprintf("%04b",$bs{team}).sprintf("%04b",$bs{id}).$bs{ready}."0");
}

sub unmarshallBattleStatus {
  my ($self,$battleStatus)=@_;
  $battleStatus+=2147483648 if($battleStatus < 0);
  my $bsBin=sprintf("%032b",$battleStatus);
  my @bs=split("",$bsBin);
  return { side => oct("0b".$bs[4].$bs[5].$bs[6].$bs[7]),
           sync => oct("0b".$bs[8].$bs[9]),
           bonus => oct("0b".$bs[14].$bs[15].$bs[16].$bs[17].$bs[18].$bs[19].$bs[20]),
           mode => $bs[21],
           team => oct("0b".$bs[22].$bs[23].$bs[24].$bs[25]),
           id => oct("0b".$bs[26].$bs[27].$bs[28].$bs[29]),
           ready => $bs[30] };
}

sub marshallColor {
  my ($self,$p_color)=@_;
  return ($p_color->{blue}*65536)+$p_color->{green}*256+$p_color->{red};
}

sub unmarshallColor {
  my ($self,$color)=@_;
  return { red => $color & 255,
           green => ($color >> 8) & 255,
           blue => ($color >> 16) & 255 };
}

sub marshallCommand {
  my ($self,$p_unmarshalled)=@_;
  my @unmarshalled=@{$p_unmarshalled};
  my $marshalled=$unmarshalled[0];
  my $command=$marshalled;
  if($command =~ /^\#\d+\s+([^\s]+)$/) {
    $command=$1;
  }
  my $sentencePos=$#unmarshalled+1;
  if(exists $sentenceStartPosClient{$command}) {
    $sentencePos=$sentenceStartPosClient{$command};
  }
  for my $i (1..$#unmarshalled) {
    $unmarshalled[$i] =~ s/\t/    /g unless(grep {/^$command$/} @tabWorkaroundCommands);
    if($i > $sentencePos) {
      $marshalled.="\t";
    }else{
      $marshalled.=" ";
    }
    $marshalled.=$unmarshalled[$i];
  }
  return $marshalled;
}

sub unmarshallCommand {
  my ($self,$marshalled)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  my $command="";
  my $marshalledParams="";
  if($marshalled =~ /^((?:\#\d+ +)?[^ ]+)((?: .*)?)$/) {
    $command=uc($1);
    $marshalledParams=$2;
  }else{
    $sl->log("Unable to unmarshall command \"$marshalled\"",1);
    return [$marshalled];
  }
  return [$command] unless($marshalledParams ne "");
  $marshalledParams=~s/^ //;
  my $realCommand=$command;
  if($command =~ /^\#\d+ +([^ ]+)$/) {
    $realCommand=$1;
  }
  my $sentenceStartPos=0;
  $sentenceStartPos=$sentenceStartPosServer{$realCommand} if(exists $sentenceStartPosServer{$realCommand});
  my @unmarshalledParams=$self->unmarshallParams($marshalledParams,$sentenceStartPos,$realCommand);
  my @unmarshalled=($command,@unmarshalledParams);
  return \@unmarshalled;
}

sub unmarshallParams {
  my ($self,$marshalledParams,$sentencePos,$command)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if($sentencePos != 1) {
    return ($marshalledParams) unless($marshalledParams =~ / /);
    if($marshalledParams =~ /^([^ ]*) (.*)$/) {
      my $param=$1;
      return ($param,$self->unmarshallParams($2,$sentencePos-1,$command));
    }else{
      $sl->log("Unable to unmarshall parameters \"$marshalledParams\"",1);
      return ($marshalledParams);
    }
  }else{
    if(grep {/^$command$/} @tabWorkaroundCommands) {
      return ($marshalledParams);
    }else{
      return split("\t",$marshalledParams);
    }
  } 
}

# Helper ######################################################################

sub aindex (\@$;$) {
  my ($aref, $val, $pos) = @_;
  for ($pos ||= 0; $pos < @$aref; $pos++) {
    return $pos if $aref->[$pos] eq $val;
  }
  return -1;
}

# Business functions ##########################################################

sub storeRunningBattle {
  my $self=shift;
  $self->{runningBattle}=dclone($self->{battles}->{$self->{battle}->{battleId}});
  foreach my $k (keys %{$self->{battle}}) {
    if(ref($self->{battle}->{$k})) {
      $self->{runningBattle}->{$k}=dclone($self->{battle}->{$k});
    }else{
      $self->{runningBattle}->{$k}=$self->{battle}->{$k};
    }
  }
  if(exists $self->{runningBattle}->{users}) {
    foreach my $user (keys %{$self->{runningBattle}->{users}}) {
      foreach my $k (keys %{$self->{users}->{$user}}) {
        if(ref($self->{users}->{$user}->{$k})) {
          $self->{runningBattle}->{users}->{$user}->{$k}=dclone($self->{users}->{$user}->{$k});
        }else{
          $self->{runningBattle}->{users}->{$user}->{$k}=$self->{users}->{$user}->{$k};
        }
      }
    }
  }
}

sub remapRunningBattleIds {
  my $self=shift;
  my $nextRemappedId=0;
  my $p_bUsers=$self->{runningBattle}->{users};
  my $p_bBots=$self->{runningBattle}->{bots};
  foreach my $player (keys %{$p_bUsers}) {
    if(defined $p_bUsers->{$player}->{battleStatus} && $p_bUsers->{$player}->{battleStatus}->{mode}) {
      $nextRemappedId=$p_bUsers->{$player}->{battleStatus}->{id}+1 if($p_bUsers->{$player}->{battleStatus}->{id} >= $nextRemappedId);
    }
  }
  foreach my $bot (keys %{$p_bBots}) {
    $nextRemappedId=$p_bBots->{$bot}->{battleStatus}->{id}+1 if($p_bBots->{$bot}->{battleStatus}->{id} >= $nextRemappedId);
  }
  my %usedIds;
  foreach my $player (keys %{$p_bUsers}) {
    if(defined $p_bUsers->{$player}->{battleStatus} && $p_bUsers->{$player}->{battleStatus}->{mode}) {
      my $playerId=$p_bUsers->{$player}->{battleStatus}->{id};
      if(exists $usedIds{$playerId}) {
        $playerId=$nextRemappedId++;
        $p_bUsers->{$player}->{battleStatus}->{id}=$playerId;
      }
      $usedIds{$playerId}=1;
    }
  }
  foreach my $bot (keys %{$p_bBots}) {
    my $botId=$p_bBots->{$bot}->{battleStatus}->{id};
    if(exists $usedIds{$botId}) {
      $botId=$nextRemappedId++;
      $p_bBots->{$bot}->{battleStatus}->{id}=$botId;
    }
    $usedIds{$botId}=1;
  }
}

# TODO: refactor this horrible function
sub generateStartData {
  my ($self,$p_additionalData,$p_sides,$p_battleData,$autoHostMode,$remapIds)=@_;
  $autoHostMode=1 unless(defined $autoHostMode);
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $p_additionalData={} unless(defined $p_additionalData);
  if(! (defined $p_battleData)) {
    if(! %{$self->{runningBattle}}) {
      if(exists $self->{battle}->{battleId}) {
        $self->storeRunningBattle();
      }else{
        $sl->log("Unable to generate start data (no battle data)",1);
        return (undef,undef,undef);
      }
    }
    $self->remapRunningBattleIds() if(defined $remapIds && $remapIds);
    $p_battleData=$self->getRunningBattle();
  }
  my %battleData=%{$p_battleData};
  if(! %battleData) {
    $sl->log("Unable to generate start data (no battle data)",1);
    return (undef,undef,undef);
  }
  
  my $myPlayerNum=0;

  my $nextTeam=0;
  my %teamsMap;
  my %teamsData;

  my $nextAllyTeam=0;
  my %allyTeamsMap;
  my %allyTeamsData;

  shift(@{$battleData{userList}}) if($autoHostMode == 1 && $battleData{userList}->[0] eq $self->{login});

  if(exists $battleData{scriptTags}->{'game/startpostype'} && $battleData{scriptTags}->{'game/startpostype'} == 1) {
    my @shuffledUserList=shuffle(@{$battleData{userList}});
    $battleData{userList}=\@shuffledUserList;
  }

  for my $userIndex (0..$#{$battleData{userList}}) {
    my $user=$battleData{userList}->[$userIndex];
    $myPlayerNum=$userIndex if($user eq $self->{login});
    my $p_battleStatus=$battleData{users}->{$user}->{battleStatus};
    if($p_battleStatus->{mode}) {
      if($p_battleStatus->{side} > $#{$p_sides}) {
        $sl->log("Side number of player \"$user\" is too big ($p_battleStatus->{side}), using max value for current MOD instead ($#{$p_sides})",2);
        $p_battleStatus->{side}=$#{$p_sides};
      }
      if(! exists $teamsMap{$p_battleStatus->{id}}) {
        my $allyTeam;
        if(! exists $allyTeamsMap{$p_battleStatus->{team}}) {
          $allyTeam=$nextAllyTeam++;
          $allyTeamsMap{$p_battleStatus->{team}}=$allyTeam;
        }else{
          $allyTeam=$allyTeamsMap{$p_battleStatus->{team}};
        }
        my $p_color = $battleData{users}->{$user}->{color};
        my $red=sprintf("%.5f",($p_color->{red} / 255));
        my $blue=sprintf("%.5f",($p_color->{blue} / 255));
        my $green=sprintf("%.5f",($p_color->{green} / 255));
        $teamsData{$nextTeam}= { TeamLeader => $userIndex,
                                 AllyTeam => $allyTeam,
                                 RgbColor => "$red $green $blue",
                                 Side => $p_sides->[$p_battleStatus->{side}],
                                 Handicap => $p_battleStatus->{bonus} };
        $teamsMap{$p_battleStatus->{id}}=$nextTeam++;
      }
    }
  }

  for my $botIndex (0..$#{$battleData{botList}}) {
    my $bot=$battleData{botList}->[$botIndex];
    my $p_battleStatus=$battleData{bots}->{$bot}->{battleStatus};
    if($p_battleStatus->{side} > $#{$p_sides}) {
      $sl->log("Side number of bot \"$bot\" is too big ($p_battleStatus->{side}), using max value for current MOD instead ($#{$p_sides})",2);
      $p_battleStatus->{side}=$#{$p_sides};
    }
    if(! exists $teamsMap{$p_battleStatus->{id}}) {
      my $allyTeam;
      if(! exists $allyTeamsMap{$p_battleStatus->{team}}) {
        $allyTeam=$nextAllyTeam++;
        $allyTeamsMap{$p_battleStatus->{team}}=$allyTeam;
      }else{
        $allyTeam=$allyTeamsMap{$p_battleStatus->{team}};
      }
      my $p_color = $battleData{bots}->{$bot}->{color};
      my $red=sprintf("%.5f",($p_color->{red} / 255));
      my $blue=sprintf("%.5f",($p_color->{blue} / 255));
      my $green=sprintf("%.5f",($p_color->{green} / 255));
      $teamsData{$nextTeam}= { AllyTeam => $allyTeam,
                               RgbColor => "$red $green $blue",
                               Side => $p_sides->[$p_battleStatus->{side}],
                               Handicap => $p_battleStatus->{bonus} };
      $teamsMap{$p_battleStatus->{id}}=$nextTeam++;
    }
    my $team=$teamsMap{$p_battleStatus->{id}};
    $teamsData{$team}->{TeamLeader}=aindex(@{$battleData{userList}},$battleData{bots}->{$bot}->{owner});
  }
  
  foreach my $allyTeam (keys %allyTeamsMap) {
    my $realAllyTeam = $allyTeamsMap{$allyTeam};
    if(exists $battleData{startRects}->{$allyTeam}) {
      $allyTeamsData{$realAllyTeam}= { StartRectTop => $battleData{startRects}->{$allyTeam}->{top}/200,
                                       StartRectLeft => $battleData{startRects}->{$allyTeam}->{left}/200,
                                       StartRectBottom => $battleData{startRects}->{$allyTeam}->{bottom}/200,
                                       StartRectRight => $battleData{startRects}->{$allyTeam}->{right}/200 };
    }else{
      $allyTeamsData{$realAllyTeam}= {};
    }
  }

  foreach my $allyTeam (sort keys %{$battleData{startRects}}) {
    next if(exists $allyTeamsMap{$allyTeam});
    $allyTeamsData{$nextAllyTeam++}= { StartRectTop => $battleData{startRects}->{$allyTeam}->{top}/200,
                                       StartRectLeft => $battleData{startRects}->{$allyTeam}->{left}/200,
                                       StartRectBottom => $battleData{startRects}->{$allyTeam}->{bottom}/200,
                                       StartRectRight => $battleData{startRects}->{$allyTeam}->{right}/200 };
  }

  my @startData=("[GAME]","{");
  push(@startData,"  Mapname=$battleData{map};");
  push(@startData,"  Gametype=$battleData{mod};");
  push(@startData,"");
  foreach my $tag (keys %{$battleData{scriptTags}}) {
    my $realTag=$tag;
    if($tag =~ /^game\/([^\/]*)$/i) {
      $realTag=$1;
    }else{
      next;
    }
    push(@startData,"  $realTag=$battleData{scriptTags}->{$tag};");
  }
  push(@startData,"");
  foreach my $tag (keys %{$p_additionalData}) {
    my $realTag=$tag;
    if($tag =~ /^game\/([^\/]*)$/i) {
      $realTag=$1;
    }else{
      next;
    }
    push(@startData,"  $realTag=$p_additionalData->{$tag};");
  }
  push(@startData,"");
  push(@startData,"  HostIP=$battleData{ip};") if($battleData{founder} ne $self->{login});
  push(@startData,"  HostPort=$battleData{port};");
  push(@startData,"");
  if($autoHostMode) {
    push(@startData,"  AutoHostName=$self->{login};");
    push(@startData,"  AutoHostCountryCode=$self->{users}->{$self->{login}}->{country};");
    push(@startData,"  AutoHostRank=$self->{users}->{$self->{login}}->{status}->{rank};");
    push(@startData,"  AutoHostAccountId=$self->{users}->{$self->{login}}->{accountId};");
    push(@startData,"");
  }
  if($autoHostMode != 1) {
    push(@startData,"  MyPlayerName=$self->{login};");
    push(@startData,"  MyPlayerNum=$myPlayerNum;");
  }
  if($battleData{founder} eq $self->{login}) {
    push(@startData,"  IsHost=1;");
  }else{
    push(@startData,"  IsHost=0;");
  }
  push(@startData,"");
  push(@startData,"  NumPlayers=".($#{$battleData{userList}}+1).";");
  push(@startData,"  NumTeams=$nextTeam;");
  push(@startData,"  NumAllyTeams=$nextAllyTeam;");
  push(@startData,"");

  for my $userIndex (0..$#{$battleData{userList}}) {
    my $user=$battleData{userList}->[$userIndex];
    my $p_battleStatus=$battleData{users}->{$user}->{battleStatus};
    my $team=$teamsMap{$p_battleStatus->{id}};
    push(@startData,"  [PLAYER$userIndex]");
    push(@startData,"  {");
    push(@startData,"    Name=$user;");
    push(@startData,"    Password=$battleData{users}->{$user}->{scriptPass};") if(defined $battleData{users}->{$user}->{scriptPass});
    push(@startData,"    Spectator=".(1 - $p_battleStatus->{mode}).";");
    push(@startData,"    Team=$team;") if($p_battleStatus->{mode});
    if(exists $self->{users}->{$user}) {
      push(@startData,"    CountryCode=$self->{users}->{$user}->{country};");
      push(@startData,"    Rank=$self->{users}->{$user}->{status}->{rank};");
      push(@startData,"    AccountId=$self->{users}->{$user}->{accountId};");
    }
    push(@startData,"  }");
  }
  for my $botIndex (0..$#{$battleData{botList}}) {
    my $bot=$battleData{botList}->[$botIndex];
    my $p_battleStatus=$battleData{bots}->{$bot}->{battleStatus};
    my $team=$teamsMap{$p_battleStatus->{id}};
    my $aiShortName=$battleData{bots}->{$bot}->{aiDll};
    my $aiVersion;
    ($aiShortName,$aiVersion)=($1,$2) if($aiShortName =~ /^([^\|]+)\|(.+)$/);
    push(@startData,"  [AI$botIndex]");
    push(@startData,"  {");
    push(@startData,"    Name=$bot;");
    push(@startData,"    ShortName=$aiShortName;");
    push(@startData,"    Team=$team;");
    push(@startData,"    Host=".aindex(@{$battleData{userList}},$battleData{bots}->{$bot}->{owner}).';');
    push(@startData,"    Version=$aiVersion;") if(defined $aiVersion);
    push(@startData,"  }");
  }

  push(@startData,"");

  for my $teamIndex (sort (keys %teamsData)) {
    push(@startData,"  [TEAM$teamIndex]");
    push(@startData,"  {");
    foreach my $k (keys %{$teamsData{$teamIndex}}) {
      push(@startData,"    $k=$teamsData{$teamIndex}->{$k};");
    }
    push(@startData,"  }"); 
  }

  push(@startData,"");

  for my $teamAllyIndex (sort (keys %allyTeamsData)) {
    push(@startData,"  [ALLYTEAM$teamAllyIndex]");
    push(@startData,"  {");
    push(@startData,"    NumAllies=0;");
    foreach my $k (keys %{$allyTeamsData{$teamAllyIndex}}) {
      push(@startData,"    $k=$allyTeamsData{$teamAllyIndex}->{$k};");
    }
    push(@startData,"  }"); 
  }

  push(@startData,"");

  push(@startData,"  NumRestrictions=".($#{$battleData{disabledUnits}}+1).";");
  push(@startData,"  [RESTRICT]");
  push(@startData,"  {");
  for my $uIndex (0..$#{$battleData{disabledUnits}}) {
    push(@startData,"    Unit$uIndex=$battleData{disabledUnits}->[$uIndex];");
    push(@startData,"    Limit$uIndex=0;");
    
  }
  push(@startData,"  }");

  push(@startData,"  [MODOPTIONS]");
  push(@startData,"  {");
  foreach my $tag (keys %{$battleData{scriptTags}}) {
    my $realTag=$tag;
    if($tag =~ /^game\/modoptions\/(.*)$/i) {
      $realTag=$1;
    }else{
      next;
    }
    push(@startData,"    $realTag=$battleData{scriptTags}->{$tag};");
  }
  push(@startData,"  }");

  push(@startData,"  [MAPOPTIONS]");
  push(@startData,"  {");
  foreach my $tag (keys %{$battleData{scriptTags}}) {
    my $realTag=$tag;
    if($tag =~ /^game\/mapoptions\/(.*)$/i) {
      $realTag=$1;
    }else{
      next;
    }
    push(@startData,"    $realTag=$battleData{scriptTags}->{$tag};");
  }
  push(@startData,"  }");

  push(@startData,"}");

  return (\@startData,\%teamsMap,\%allyTeamsMap);
}

sub addCallbacks {
  my ($self,$p_callbacks,$nbCalls)=@_;
  if(! (defined $nbCalls)) {
    $nbCalls=0;
  }
  my %callbacks=%{$p_callbacks};
  foreach my $command (keys %callbacks) {
    $self->{callbacks}->{$command}=[$callbacks{$command},$nbCalls];
  }
}

sub removeCallbacks {
  my ($self,$p_commands)=@_;
  my @commands=@{$p_commands};
  foreach my $command (@commands) {
    delete $self->{callbacks}->{$command};
  }
}

sub addPreCallbacks {
  my ($self,$p_preCallbacks)=@_;
  foreach my $command (keys %{$p_preCallbacks}) {
    $self->{preCallbacks}->{$command}=$p_preCallbacks->{$command};
  }
}

sub removePreCallbacks {
  my ($self,$p_commands)=@_;
  foreach my $command (@{$p_commands}) {
    delete $self->{preCallbacks}->{$command};
  }
}

sub checkTimeouts {
  my $self = shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  foreach my $pr (keys %{$self->{pendingRequests}}) {
    my ($p_callbacks,$timeout,$p_timeoutCallback)=@{$self->{pendingRequests}->{$pr}};
    if(time > $timeout) {
      $sl->log("Timeout for request \"$pr\"",2);
      foreach my $cbtr (keys %{$p_callbacks}) {
        delete $self->{pendingResponses}->{$cbtr};
      }
      delete $self->{pendingRequests}->{$pr};
      if($p_timeoutCallback) {
        &{$p_timeoutCallback}($pr);
      }
    }
  }
}

sub connect {
  my ($self,$disconnectCallback,$p_callbacks,$timeoutCallback) = @_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("Connecting to $conf{serverHost}:$conf{serverPort}",3);
  if((defined $self->{lobbySock}) && $self->{lobbySock}) {
    $sl->log("Could not connect to lobby server, already connected!",2);
    return $self->{lobbySock};
  }
  $self->{lobbySock} = new IO::Socket::INET(PeerHost => $conf{serverHost},
                                            PeerPort => $conf{serverPort},
                                            Proto => 'tcp',
                                            Blocking => 0,
                                            Timeout => $conf{timeout});
  if(! $self->{lobbySock}) {
    $sl->log("Unable to connect to lobby server $conf{serverHost}:$conf{serverPort} ($@)",0);
    undef $self->{lobbySock};
    return 0;
  }
  $self->{callbacks}->{"_DISCONNECT_"}=$disconnectCallback if(defined $disconnectCallback);
  if(defined $p_callbacks) {
    my %callbacks=%{$p_callbacks};
    if(%callbacks) {
      if(! defined $timeoutCallback) {
        $timeoutCallback=0;
      }
      foreach my $response (keys %callbacks) {
        $self->{pendingResponses}->{$response}="_CONNECT_";
      }
      $self->{pendingRequests}->{"_CONNECT_"}=[$p_callbacks,time+$conf{timeout},$timeoutCallback];
    }
  }
  return $self->{lobbySock};
}

sub disconnect {
  my $self = shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("Disconnecting from $conf{serverHost}:$conf{serverPort}",3);
  if(! ((defined $self->{lobbySock}) && $self->{lobbySock})) {
    $sl->log("Unable to disconnect from lobby server, already disconnected!",2);
  }else{
    close($self->{lobbySock});
    undef $self->{lobbySock};
  }
  $self->{login}=undef;
  $self->{users}={};
  $self->{accounts}={};
  $self->{channels}={};
  $self->{battles}={};
  $self->{battle}={};
  $self->{runningBattle}={};
  $self->{callbacks}={};
  $self->{preCallbacks}={};
  $self->{pendingRequests}={};
  $self->{pendingResponses}={};
  $self->{openBattleModHash}=0;
  $self->{password}="*";
}

sub sendCommand {
  my ($self,$p_command,$p_callbacks,$p_timeoutCallback) = @_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(! ((defined $self->{lobbySock}) && $self->{lobbySock})) {
    $sl->log("Unable to send command, not connected to lobby server",1);
    return 0;
  }
  my $commandName=$p_command->[0];
  if($commandName =~ /^\#\d+\s+([^\s]+)$/) {
    $commandName=$1;
  }
  if(exists $commandHooks{$commandName}) {
    my $hook=$commandHooks{$commandName};
    &{$hook}($self,@{$p_command});
  }
  my $lobbySock=$self->{lobbySock};
  my $command=$self->marshallCommand($p_command);
  $sl->log("Sending to lobby server: \"$command\"",5);
  my $printRc=print $lobbySock "$command\n";
  if(! defined $printRc) {
    $sl->log("Failed to send following command to lobby server \"$command\" ($!)",1);
    return 0;
  }
  if(defined $p_callbacks) {
    my %callbacks=%{$p_callbacks};
    if(%callbacks) {
      if(! defined $p_timeoutCallback) {
        $p_timeoutCallback=0;
      }
      foreach my $response (keys %callbacks) {
        $self->{pendingResponses}->{$response}=$p_command->[0];
      }
      $self->{pendingRequests}->{$p_command->[0]}=[$p_callbacks,time+$conf{timeout},$p_timeoutCallback];
    }
  }
  return 1;
}

sub receiveCommand {
  my $self=shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(! ((defined $self->{lobbySock}) && $self->{lobbySock})) {
    $sl->log("Unable to receive command from lobby server, not connected!",1);
    return 0;
  }
  my $lobbySock=$self->{lobbySock};
  my @commands;
  if($^O eq 'MSWin32') {
    my $select=IO::Select->new($lobbySock);
    while($select->can_read(0)) {
      my $line=$lobbySock->getline();
      last unless(defined $line);
      push(@commands,$line);
    }
  }else{
    @commands=$lobbySock->getlines();
  }
  if(! @commands) {
    $sl->log("Connection reset by peer or library used with unready socket",2);
    if(exists $self->{callbacks}->{"_DISCONNECT_"}) {
      &{$self->{callbacks}->{"_DISCONNECT_"}}();
    }
    return 0;
  }
  my $rc=1;
  for my $commandNb (0..$#commands) {
    my $marshalledCommand=$commands[$commandNb];
    if($commandNb == 0) {
      $marshalledCommand=$self->{readBuffer}.$marshalledCommand;
      $self->{readBuffer}="";
    }
    if($commandNb == $#commands && $marshalledCommand !~ /\n$/) {
      $self->{readBuffer}=$marshalledCommand;
      last;
    }
    chomp($marshalledCommand);
    if($marshalledCommand eq "") {
      $sl->log("Ignoring empty command received from lobby server",5);
      next;
    } 
    my $p_command=$self->unmarshallCommand($marshalledCommand);
    $sl->log("Received from lobby server: \"$marshalledCommand\", unmarshalled as:\"".join(",",@{$p_command})."\"",5);
    my $commandName=$p_command->[0];
    my $realCommandName=$commandName;
    if($commandName =~ /^\#\d+\s+([^\s]+)$/) {
      $realCommandName=$1;
    }
    my $processed=0;
    
    if(exists($self->{preCallbacks}->{$realCommandName})) {
      $processed=1;
      my $p_preCallback=$self->{preCallbacks}->{$realCommandName};
      &{$p_preCallback}(@{$p_command}) if($p_preCallback);
    }

    my ($handlerTime,$callbackTime);
    if(exists($commandHandlers{$realCommandName})) {
      $processed=1;
      $handlerTime=time;
      $rc = &{$commandHandlers{$realCommandName}}($self,@{$p_command}) && $rc if($commandHandlers{$realCommandName});
      $handlerTime=time-$handlerTime;
    }
    my $cName="_DEFAULT_";
    if(exists($self->{callbacks}->{$realCommandName})) {
      $cName=$realCommandName;
    }
    if(exists($self->{callbacks}->{$commandName})) {
      $cName=$commandName;
    }
    if(exists($self->{callbacks}->{$cName})) {
      my ($callback,$nbCalls)=@{$self->{callbacks}->{$cName}};
      $processed=1;
      if($nbCalls == 1) {
        delete $self->{callbacks}->{$cName};
      }elsif($nbCalls > 1) {
        $nbCalls-=1;
        $self->{callbacks}->{$cName}=[$callback,$nbCalls];
      }
      $callbackTime=time;
      $rc = &{$callback}(@{$p_command}) && $rc if($callback);
      $callbackTime=time-$callbackTime;
    }
    if(defined $handlerTime) {
      if(defined $callbackTime) {
        if($handlerTime || $callbackTime) {
          my $statsLevel=5;
          my $maxTime=$handlerTime;
          $maxTime=$callbackTime if($callbackTime > $handlerTime);
          $statsLevel=4 if($maxTime > 1);
          $sl->log("Stats for $realCommandName: internal handler took $handlerTime second(s) and callback took $callbackTime second(s)",$statsLevel);
        }
      }elsif($handlerTime) {
        my $statsLevel=5;
        $statsLevel=4 if($handlerTime > 1);
        $sl->log("Stats for $realCommandName: internal handler took $handlerTime second(s)",$statsLevel);
      }
    }elsif(defined $callbackTime && $callbackTime) {
      my $statsLevel=5;
      $statsLevel=4 if($callbackTime > 1);
      $sl->log("Stats for $realCommandName: callback took $callbackTime second(s)",$statsLevel);
    }
    $cName=$realCommandName;
    if(exists($self->{pendingResponses}->{$commandName})) {
      $cName=$commandName;
    }
    if(exists($self->{pendingResponses}->{$cName})) {
      my $request=$self->{pendingResponses}->{$cName};
      my ($p_callbacks,$timeout,$p_timeoutCallback)=@{$self->{pendingRequests}->{$request}};
      my $callback=$p_callbacks->{$cName};
      foreach my $cbtr (keys %{$p_callbacks}) {
        delete $self->{pendingResponses}->{$cbtr};
      }
      delete $self->{pendingRequests}->{$request};
      $processed=1;
      $rc = &{$callback}(@{$p_command}) && $rc if($callback);
    }
    if(! $processed && $conf{warnForUnhandledMessages}) {
      $sl->log("Unexpected/unhandled command received: \"$marshalledCommand\"",2);
      $rc=0;
    }
  }
  return $rc;
};

# Internal handlers and hooks #################################################

sub checkIntParams {
  my ($self,$commandName,$p_paramNames,$p_paramPointers)=@_;
  if($#{$p_paramNames} != $#{$p_paramPointers}) {
    $self->{conf}->{simpleLog}->log("Invalid call of checkIntParams: paramNames length is $#{$p_paramNames} whereas paramPointers length is $#{$p_paramPointers}",1);
    return {};
  }
  my %invalidParams;
  for my $i (0..$#{$p_paramNames}) {
    if(${$p_paramPointers->[$i]} !~ /^-?\d+$/) {
      $invalidParams{$p_paramNames->[$i]}=${$p_paramPointers->[$i]};
      $self->{conf}->{simpleLog}->log("Found invalid $p_paramNames->[$i] parameter value \"${$p_paramPointers->[$i]}\" (should be integer) in lobby command $commandName",2);
      ${$p_paramPointers->[$i]}=0;
    }
  }
  return \%invalidParams;
}

sub acceptedHandler {
  my ($self,undef,$login)=@_;
  $self->{login}=$login;
  return 1;
}

sub addUserHandler {
  my ($self,undef,$user,$country,$cpu,$accountId)=@_;
  $accountId=0 unless(defined $accountId);
  $self->checkIntParams('ADDUSER',[qw/cpu accountId/],[\$cpu,\$accountId]);
  $self->{users}->{$user} = { country => $country,
                              cpu => $cpu,
                              accountId => $accountId,
                              ip => undef,
                              status => { inGame => 0,
                                          rank => 0,
                                          away => 0,
                                          access => 0,
                                          bot => 0 } };
  $self->{accounts}->{$accountId}=$user if($accountId);
  return 1;
}

sub removeUserHandler {
  my ($self,undef,$user)=@_;
  delete $self->{accounts}->{$self->{users}->{$user}->{accountId}} if($self->{users}->{$user}->{accountId});
  delete $self->{users}->{$user};
  return 1;
}

sub clientStatusHandler {
  my ($self,undef,$user,$status)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{users}->{$user}) {
    my $p_clientStatus = $self->unmarshallClientStatus($status);
    if($user eq $self->{login}) {
      my $currentInGameStatus=$self->{users}->{$user}->{status}->{inGame};
      if( $currentInGameStatus == 0 && $p_clientStatus->{inGame} == 1) {
        if(exists $self->{battle}->{battleId}) {
          $self->storeRunningBattle();
        }
      }elsif($currentInGameStatus == 1 && $p_clientStatus->{inGame} == 0) {
        $self->{runningBattle}={};
      }
    }
    $self->{users}->{$user}->{status}=$p_clientStatus;
  }else{
    $sl->log("Ignoring CLIENTSTATUS command (unknown user:\"$user\")",1);
    return 0;
  }
  return 1;
}

sub joinHandler {
  my ($self,undef,$channel)=@_;
  $self->{channels}->{$channel}={};
  return 1;
}

sub clientsHandler {
  my ($self,undef,$channel,$usersList)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{channels}->{$channel}) {
    my @users=split(" ",$usersList);
    foreach my $user (@users) {
      $self->{channels}->{$channel}->{$user}=1;
    }
  }else{
    $sl->log("Ignoring CLIENTS command (non joined channel:\"$channel\")",1);
    return 0;
  }
  return 1;
}

sub joinedHandler {
  my ($self,undef,$channel,$user)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{channels}->{$channel}) {
    $self->{channels}->{$channel}->{$user}=1;
  }else{
    $sl->log("Ignoring JOINED command (non joined channel:\"$channel\")",1);
    return 0;
  }
  return 1;
}

sub leftHandler {
  my ($self,undef,$channel,$user)=@_;
  delete $self->{channels}->{$channel}->{$user};
  return 1;
}

sub leaveChannelHandler {
  my ($self,undef,$channel)=@_;
  delete $self->{channels}->{$channel};
  return 1;
}

sub battleOpenedHandler {
  my ($self,undef,$battleId,$type,$natType,$founder,$ip,$port,$maxPlayers,$passworded,$rank,$mapHash,$map,$title,$mod)=@_;
  $self->checkIntParams('BATTLEOPENED',[qw/battleId type natType port maxPlayers passworded rank mapHash/],[\$battleId,\$type,\$natType,\$port,\$maxPlayers,\$passworded,\$rank,\$mapHash]);
  $self->{battles}->{$battleId} = { type => $type,
                                    natType => $natType,
                                    founder => $founder,
                                    ip => $ip,
                                    port => $port,
                                    maxPlayers => $maxPlayers,
                                    passworded => $passworded,
                                    rank => $rank,
                                    mapHash => $mapHash,
                                    map => $map,
                                    title => $title,
                                    mod => $mod,
                                    userList => [$founder],
                                    nbSpec => 0,
                                    locked => 0};
  return 1;
}

sub battleClosedHandler {
  my ($self,undef,$battleId)=@_;
  delete $self->{battles}->{$battleId};
  $self->{battle}={} if(exists $self->{battle}->{battleId} && $self->{battle}->{battleId} == $battleId);
  return 1;
}

sub joinedBattleHandler {
  my ($self,undef,$battleId,$user,$scriptPass)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battles}->{$battleId}) {
    push(@{$self->{battles}->{$battleId}->{userList}},$user);
    if(exists $self->{battle}->{battleId}) {
      if($battleId eq $self->{battle}->{battleId}) {
        $self->{battle}->{users}->{$user}={battleStatus => undef, color => undef, ip => undef, port => undef, scriptPass => $scriptPass};
      }
    }
  }else{
    $sl->log("Ignoring JOINEDBATTLE command (unknown battle:\"$battleId\")",1);
    return 0;
  }
  return 1;
}

sub leftBattleHandler {
  my ($self,undef,$battleId,$user)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battles}->{$battleId}) {
    my @userList=@{$self->{battles}->{$battleId}->{userList}};
    my $userIndex=aindex(@userList,$user);
    if($userIndex != -1) {
      splice(@userList,$userIndex,1);
      $self->{battles}->{$battleId}->{userList}=\@userList;
    }else{
      $sl->log("Ignoring LEFTBATTLE command (user already out of battle:\"$user\")",1);
      return 0;
    }
    if(exists $self->{battle}->{battleId}) {
      if($battleId eq $self->{battle}->{battleId}) {
        delete $self->{battle}->{users}->{$user};
      }
    }
    $self->{battle}={} if($user eq $self->{login});
  }else{
    $sl->log("Ignoring LEFTBATTLE command (unknown battle:\"$battleId\")",1);
    return 0;
  }
  return 1;
}

sub updateBattleInfoHandler {
  my ($self,undef,$battleId,$nbSpec,$locked,$mapHash,$map)=@_;
  $self->checkIntParams('UPDATEBATTLEINFO',[qw/battleId nbSpec locked mapHash/],[\$battleId,\$nbSpec,\$locked,\$mapHash]);
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battles}->{$battleId}) {
    $self->{battles}->{$battleId}->{nbSpec}=$nbSpec;
    $self->{battles}->{$battleId}->{locked}=$locked;
    $self->{battles}->{$battleId}->{mapHash}=$mapHash;
    if(exists $self->{battle}->{battleId} && $self->{battle}->{battleId} == $battleId && $self->{battles}->{$battleId}->{map} ne $map) {
      if(exists $self->{battle}->{scriptTags}) {
        my $p_scriptTags=$self->{battle}->{scriptTags};
        my @mapOptions;
        foreach my $scriptTag (keys %{$p_scriptTags}) {
          push(@mapOptions,$scriptTag) if($scriptTag =~ /^game\/mapoptions\//i);
        }
        foreach my $mapOption (@mapOptions) {
          delete($p_scriptTags->{$mapOption});
        }
      }
    }
    $self->{battles}->{$battleId}->{map}=$map;
  }else{
    $sl->log("Ignoring UPDATEBATTLEINFO command (unknown battle:\"$battleId\")",1);
    return 0;
  }
  return 1;
}

sub openBattleHook {
  my $self=shift;
  $self->{password}=$_[3];
  $self->{openBattleModHash}=$_[6];
  return 1;
}

sub openBattleHandler {
  my ($self,undef,$battleId)=@_;
  $self->checkIntParams('OPENBATTLE',['battleId'],[\$battleId]);
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battles}->{$battleId}) {
    $self->{battle} = { battleId => $battleId,
                        users => {},
                        bots => {},
                        botList => [],
                        founder => $self->{battles}->{$battleId}->{founder},
                        disabledUnits => [],
                        startRects => {},
                        scriptTags => {},
                        modHash => $self->{openBattleModHash},
                        password => $self->{password} };
    foreach my $user (@{$self->{battles}->{$battleId}->{userList}}) {
      $self->{battle}->{users}->{$user}={battleStatus => undef, color => undef, ip => undef, port => undef};
    }
  }else{
    $sl->log("Ignoring OPENBATTLE command (unknown battle:\"$battleId\")",1);
    return 0;
  }
  return 1;
}

sub joinBattleHook {
  my $self=shift;
  $self->{password}=$_[2];
  return 1;
}

sub joinBattleHandler {
  my ($self,undef,$battleId,$modHash)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battles}->{$battleId}) {
    $self->{battle} = { battleId => $battleId,
                        users => {},
                        bots => {},
                        botList => [],
                        founder => $self->{battles}->{$battleId}->{founder},
                        disabledUnits => [],
                        startRects => {},
                        scriptTags => {},
                        modHash => $modHash,
                        password => $self->{password} };
    foreach my $user (@{$self->{battles}->{$battleId}->{userList}}) {
      $self->{battle}->{users}->{$user}={battleStatus => undef, color => undef, ip => undef, port => undef};
    }
  }else{
    $sl->log("Ignoring JOINBATTLE command (unknown battle:\"$battleId\")",1);
    return 0;
  }
  return 1;
}

sub joinBattleRequestHandler {
  my ($self,undef,$user,$ip)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{users}->{$user}) {
    $self->{users}->{$user}->{ip}=$ip;
  }else{
    $sl->log("Ignoring JOINBATTLEREQUEST command (client \"$user\" offline)",1);
    return 0;
  }
}

sub clientIpPortHandler {
  my ($self,undef,$user,$ip,$port)=@_;
  $self->checkIntParams('CLIENTIPPORT',['port'],[\$port]);
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{users}) {
    if(exists $self->{battle}->{users}->{$user}) {
      $self->{battle}->{users}->{$user}->{ip}=$ip;
      $self->{battle}->{users}->{$user}->{port}=$port;
    }else{
      $sl->log("Ignoring CLIENTIPPORT command (client \"$user\" out of current battle)",1);
      return 0;
    }
  }else{
    $sl->log("Ignoring CLIENTIPPORT command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub clientBattleStatusHandler {
  my ($self,undef,$user,$battleStatus,$color)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{users}) {
    if(exists $self->{battle}->{users}->{$user}) {
      $self->{battle}->{users}->{$user}->{battleStatus}=$self->unmarshallBattleStatus($battleStatus);
      $self->{battle}->{users}->{$user}->{color}=$self->unmarshallColor($color);
    }else{
      $sl->log("Ignoring CLIENTBATTLESTATUS command (client \"$user\" out of current battle)",1);
      return 0;
    }
  }else{
    $sl->log("Ignoring CLIENTBATTLESTATUS command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub disableUnitsHandler {
  my ($self,undef,@units)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{disabledUnits}) {
    push(@{$self->{battle}->{disabledUnits}},@units);
  }else{
    $sl->log("Ignoring DISABLEUNITS command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub enableUnitsHandler {
  my ($self,undef,@units)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{disabledUnits}) {
    my @disabledUnits=@{$self->{battle}->{disabledUnits}};
    foreach my $u (@units) {
      my $unitIndex = aindex(@disabledUnits,$u);
      if($unitIndex != -1) {
        splice(@disabledUnits,$unitIndex,1);
      }else{
        $sl->log("Ignoring ENABLEUNITS for unit $u (already unabled)",1);
      }
    }
    $self->{battle}->{disabledUnits}=\@disabledUnits;
  }else{
    $sl->log("Ignoring ENABLEUNITS command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub enableAllUnitsHandler  {
  my ($self,undef)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{disabledUnits}) {
    $self->{battle}->{disabledUnits}=[];
  }else{
    $sl->log("Ignoring ENABLEALLUNITS command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub addBotHandler {
  my ($self,undef,$battleId,$name,$owner,$battleStatus,$color,$aiDll)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{battleId}) {
    if($battleId == $self->{battle}->{battleId}) {
      push(@{$self->{battle}->{botList}},$name);
      $self->{battle}->{bots}->{$name} = { owner => $owner,
                                           battleStatus => $self->unmarshallBattleStatus($battleStatus),
                                           color => $self->unmarshallColor($color),
                                           aiDll => $aiDll };
    }else{
      $sl->log("Ignoring ADDBOT command (wrong battle ID:\"$battleId\")",1);
      return 0;
    }
  }else{
    $sl->log("Ignoring ADDBOT command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub removeBotHandler {
  my ($self,undef,$battleId,$name)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{battleId}) {
    if($battleId == $self->{battle}->{battleId}) {
      my @botList=@{$self->{battle}->{botList}};
      my $botIndex=aindex(@botList,$name);
      if($botIndex != -1) {
        splice(@botList,$botIndex,1);
        $self->{battle}->{botList}=\@botList;
      }else{
        $sl->log("Ignoring REMOVEBOT command (unknown bot \"$name\")",1);
        return 0;
      }
      delete $self->{battle}->{bots}->{$name};
    }else{
      $sl->log("Ignoring REMOVEBOT command (wrong battle ID:\"$battleId\")",1);
      return 0;
    }
  }else{
    $sl->log("Ignoring REMOVEBOT command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub updateBotHandler {
  my ($self,undef,$battleId,$name,$battleStatus,$color)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{battleId}) {
    if($battleId == $self->{battle}->{battleId}) {
      $self->{battle}->{bots}->{$name}->{battleStatus}=$self->unmarshallBattleStatus($battleStatus);
      $self->{battle}->{bots}->{$name}->{color}=$self->unmarshallColor($color);
    }else{
      $sl->log("Ignoring UPDATEBOT command (wrong battle ID:\"$battleId\")",1);
      return 0;
    }
  }else{
    $sl->log("Ignoring UPDATEBOT command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub addStartRectHandler {
  my ($self,undef,$id,$left,$top,$right,$bottom)=@_;
  $self->checkIntParams('ADDSTARTRECT',[qw/id left top right bottom/],[\$id,\$left,\$top,\$right,\$bottom]);
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{startRects}) {
    $self->{battle}->{startRects}->{$id}={ left => $left, top => $top, right => $right, bottom => $bottom };
  }else{
    $sl->log("Ignoring ADDSTARTRECT command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

sub removeStartRectHandler {
  my ($self,undef,$id)=@_;
  delete $self->{battle}->{startRects}->{$id};
  return 1;
}

sub setScriptTagsHandler {
  my ($self,undef,@scriptTags)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{battle}->{scriptTags}) {
    foreach my $tagValue (@scriptTags) {
      if($tagValue =~ /^\s*([^=]*[^=\s])\s*=\s*(.*[^\s])\s*$/) {
        $self->{battle}->{scriptTags}->{$1}=$2;
      }else{
        $sl->log("Ignoring invalid script tag \"$tagValue\"",2);
      }
    }
  }else{
    $sl->log("Ignoring SETSCRIPTTAGS command (currently out of any battle)",1);
    return 0;
  }
  return 1;
}

1;
