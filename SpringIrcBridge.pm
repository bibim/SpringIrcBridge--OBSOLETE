# Perl class implementing translation between IRC commands and Spring
# lobby commands.
#
# Copyright (C) 2013  Yann Riou <yannriou0@gmail.com>
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

package SpringIrcBridge;

use strict;

use IO::Select;

use SimpleLog;
use PerlLobbyInterface;

# Internal data ###############################################################

my $springHost='lobby.springrts.com';

my %ircHandlers = (
  nick => \&hNick,
  pass => \&hPass,
  user => \&hUser,
  pong => \&hNull,
  userhost => \&hUserHost,
  join => \&hJoin,
  mode => \&hMode,
  whois => \&hWhois,
  who => \&hWho,
  list => \&hList,
  part => \&hPart,
  quit => \&hQuit,
  privmsg => \&hPrivMsg,
  notice => \&hNotice,
  ping => \&hPing,
  away => \&hAway,
  topic => \&hTopic,
  ison => \&hIsOn
);

# Constructor #################################################################

my $self;

sub new {
  my ($objectOrClass,$sock,$nbClient) = @_;
  my $class = ref($objectOrClass) || $objectOrClass;

  $sock->blocking(0);
  my $ip=$sock->peerhost();

  $self = {
    nbClient => $nbClient,
    simpleLog => SimpleLog->new(logFiles => ["bridge_$ip.log",""],
                                logLevels => [4,3],
                                useANSICodes => [0,1],
                                useTimestamps => [1,1],
                                prefix => "[PerlIRCInterface($$)] "),
    ircSock => $sock,
    ircState => 0,
    lobbySock => undef,
    lobbyState => 0,
    login => undef,
    password => undef,
    timestamps => {ircConnection => time,
                   connectAttempt => 0,
                   broadcast => 0},
    lobby => PerlLobbyInterface->new(simpleLog => SimpleLog->new(logFiles => ["bridge_$ip.log",""],
                                                                 logLevels => [4,3],
                                                                 useANSICodes => [0,1],
                                                                 useTimestamps => [1,1],
                                                                 prefix => "[PerlLobbyInterface($$)] "),
                                     warnForUnhandledMessages => 0),
    exiting => 0,
    pendingChan => undef,
    pendingQuit => {},
    ident => undef,
    host => undef,
    isInLocal => 0,
    isInDebug => 0,
    isInDebugIrc => 0,
    isInDebugLobby => 0,
    battle => undef,
    battleData => {topic => undef,
                   inviteOnly => undef},
    userModes => {},
    userBattles => {},
    pendingBattle => undef,
    statusMode => 1,
    wallopMode => 1,
    ircTimeout => 120,
    lobbyTimeout => 60,
    lowerCaseClients => {}
  };

  bless ($self, $class);
  return $self;
}

sub logSuffix {
  my $login=$self->{login} || '?';
  my $host=$self->{host} || '?';
  my $ip='?';
  $ip=$self->{ircSock}->peerhost() if(defined $self->{ircSock} && $self->{ircSock} && $self->{ircSock}->connected);
  return " ($login {$host [$ip]})";
}

sub run {
  my $sl=$self->{simpleLog};
  my $ircSock=$self->{ircSock};
  $self->send("NOTICE AUTH :*** IRC bridge for Spring lobby server (use your Spring login and password to connect)");
  $self->send("NOTICE AUTH :*** Looking up your hostname");
  my @hosts = gethostbyaddr($self->{ircSock}->peeraddr(),2);
  if(defined $hosts[0]) {
    $self->{host}=$hosts[0];
  }else{
    $self->{host}=$self->{ircSock}->peerhost();
  }
  $self->send("NOTICE AUTH :*** Found your hostname");
  while(! $self->{ircState}) {
    return if($self->{exiting});
    if(time - $self->{timestamps}->{ircConnection} > 30) {
      $self->send("NOTICE AUTH :*** Authentication timeout, closing connection");
      $self->hDisconnect('authentication timeout');
      return;
    }
    my @pendingSockets=IO::Select->new($ircSock)->can_read(1);
    next unless(@pendingSockets);
    $self->receiveCommand();
  }
  $self->send("PING :".time());
  $self->{timestamps}->{ircPing}=time;
  $self->{timestamps}->{ircPong}=time;
  while($self->{ircState} && ! $self->{exiting}) {
    if(time - $self->{timestamps}->{ircPong} > $self->{ircTimeout}) {
      $self->send("NOTICE :*** Timeout!");
      $self->hDisconnect('IRC timeout');
      return;
    }
    my $halfTimeout=int($self->{ircTimeout}/2);
    if(time - $self->{timestamps}->{ircPong} > $halfTimeout && time - $self->{timestamps}->{ircPing} > $halfTimeout) {
      $self->send("PING :$springHost");
      $self->{timestamps}->{ircPing}=time;
    }
    my @sockets=($ircSock);
    if(! $self->{lobbyState}) {
      if(time-$self->{timestamps}->{connectAttempt} > 30 && $self->{login} ne '') {
        $self->{timestamps}->{connectAttempt}=time;
        $self->{lobbyState}=1;
        $self->{lobby}->addCallbacks({REDIRECT => \&cbRedirect});
        $sl->log("Connecting to lobby server, IRC ident: \"$self->{ident}\"".logSuffix(),4);
        my $lSock = $self->{lobby}->connect(\&hDisconnect,{TASSERVER => \&cbLobbyConnect},\&cbConnectTimeout);
        $self->{timestamps}->{lobbyPing}=time;
        $self->{timestamps}->{lobbyPong}=time;
        if($lSock) {
          push(@sockets,$lSock);
        }else{
          $self->{lobbyState}=0;
          $sl->log("Connection to lobby server failed".logSuffix(),1);
        }
      }
    }else{
      push(@sockets,$self->{lobby}->{lobbySock});
      if(time - $self->{timestamps}->{lobbyPing} > 15) {
        $self->{timestamps}->{lobbyPing}=time;
        $self->{lobby}->sendCommand(["PING"]);        
      }
      if(time - $self->{timestamps}->{lobbyPong} > $self->{lobbyTimeout}) {
        $self->send("NOTICE :*** Lobby timeout!");
        $self->hDisconnect('lobby timeout');
        return;
      }
    }
    if(-f "BROADCAST.txt") {
      my @broadcastStat=stat("BROADCAST.txt");
      $self->{timestamps}->{broadcast}=$broadcastStat[9] if($self->{timestamps}->{broadcast} == 0);
      if($broadcastStat[9] > $self->{timestamps}->{broadcast}) {
        $self->{timestamps}->{broadcast}=$broadcastStat[9];
        my @broadcastMsg;
        if(open(BROADCASTMSG,"<BROADCAST.txt")) {
          while(<BROADCASTMSG>) {
            chomp();
            push(@broadcastMsg,$_);
          }
          close(BROADCASTMSG);
          foreach my $bcMsg (@broadcastMsg) {
            $self->send(":$springHost NOTICE $self->{login} :[IRC BRIDGE MESSAGE] $bcMsg");
          }
        }else{
          $sl->log("Unable to open BROADCAST.txt file".logSuffix(),1);
        }
      }
    }
    my @pendingSockets=IO::Select->new(@sockets)->can_read(1);
    foreach my $pendingSock (@pendingSockets) {
      if($pendingSock == $ircSock) {
        $self->receiveCommand();
      }else{
        $self->{timestamps}->{lobbyPong}=time;
        $self->{lobby}->receiveCommand();
      }
    }
  }
}

sub hDisconnect {
  my (undef,$reason)=@_;
  my $mes='Disconnecting IRC bridge session';
  $mes.=" - $reason" if(defined $reason);
  $self->{simpleLog}->log($mes.logSuffix(),4);
  $self->{ircSock}->close();
  if($self->{lobbyState}) {
    if($self->{lobbyState} > 3) {
      $reason='reason unknown' unless(defined $reason && $reason ne '');
      my %lobbyReasons=('IRC timeout' => 'IRC connection timeout',
                        'lobby timeout' => 'Lobby connection timeout',
                        'IRC connection closed' => 'IRC connection reset by peer',
                        'IRC connection reset by peer' => 'IRC connection reset by peer',
                        'normal quit' => 'Exiting');
      my $lobbyReason=$reason;
      $lobbyReason=$lobbyReasons{$reason} if(exists $lobbyReasons{$reason});
      $self->{lobby}->sendCommand(["EXIT",$lobbyReason]);
    }
    $self->{lobby}->disconnect();
  }
  $self->{exiting}=1;
}

sub send {
  my (undef,$command)=@_;
  my $sl=$self->{simpleLog};
  my $ircNameString="";
  if(defined $self->{login}) {
    $ircNameString=" ".$self->{login};
  }
  $sl->log("Sending to IRC client$ircNameString: \"$command\"",5);
  if(! ((defined $self->{ircSock}) && $self->{ircSock} && $self->{ircSock}->connected)) {
    $sl->log("Unable to send command \"$command\" to IRC client, not connected!".logSuffix(),1);
  }else{
    my $ircSock=$self->{ircSock};
    print $ircSock $command."\n";
    print $ircSock ":IrcBridge PRIVMSG \&debug_irc :-> $command\n" if($self->{isInDebugIrc} == 1);
    print $ircSock ":IrcBridge PRIVMSG \&debug :-> $command\n" if($self->{isInDebug} == 1);
  }
}

sub sendDebugChan {
  my ($internalChan,$command)=@_;
  if((defined $self->{ircSock}) && $self->{ircSock} && $self->{ircSock}->connected) {
    my $ircSock=$self->{ircSock};
    print $ircSock ":IrcBridge PRIVMSG \&$internalChan :<- $command\n";
  }
}

sub receiveCommand {
  my $sl=$self->{simpleLog};
  if(! ((defined $self->{ircSock}) && $self->{ircSock} && $self->{ircSock}->connected)) {
    $sl->log("Unable to receive command from IRC client, not connected!".logSuffix(),1);
    $self->hDisconnect('IRC connection closed');
    return 0;
  }
  my $ircSock=$self->{ircSock};
  my @commands;
  if($^O eq 'MSWin32') {
    my $select=IO::Select->new($ircSock);
    while($select->can_read(0)) {
      my $line=$ircSock->getline();
      last unless(defined $line);
      push(@commands,$line);
    }
  }else{
    @commands=$ircSock->getlines();
  }
  if(! @commands) {
    $sl->log("Connection reset by peer or library used with unready socket".logSuffix(),2);
    $self->hDisconnect('IRC connection reset by peer');
    return 0;
  }
  $self->{timestamps}->{ircPong}=time;
  foreach my $command (@commands) {
    $command =~ s/\n//g;
    $command =~ s/\r//g;
    chomp($command);
    my $ircNameString="";
    if(defined $self->{login}) {
      $ircNameString=" ".$self->{login};
    }
    $sl->log("Received from IRC client$ircNameString: \"$command\"",5);
    sendDebugChan('debug_irc',$command) if($self->{isInDebugIrc} == 1);
    sendDebugChan('debug',$command) if($self->{isInDebug} == 1);
    $command=$1 if($command =~ /^:[^ ]+ (.*)$/);
    my ($commandName,$parameters)=("","");
    if($command =~ /^([^ ]+)(.*)$/) {
      $commandName=lc($1);
      $parameters=$1 if($2 =~ /^ (.+)$/);
    }else{
      $sl->log("Ignoring invalid command received from IRC client \"$command\"".logSuffix(),2) if($command ne '');
      next;
    }
    if(exists $ircHandlers{$commandName}) {
      &{$ircHandlers{$commandName}}($self,$parameters);
    }else{
      $sl->log("Ignoring unknown command received from IRC client \"$command\"".logSuffix(),2);
      $command=~s/://g;
      if($command =~/^ *([^ ]+)/) {
        $command=$1;
        $self->send(":$springHost 421$ircNameString $command :Unknown command");
      }
    }
  }
}


sub checkBattleTopic {
  return unless(defined $self->{battle});
  my ($newTopic)=makeBattleString($self->{battle},0);
  return unless(! defined $self->{battleData}->{topic} || $self->{battleData}->{topic} ne $newTopic);
  $self->{battleData}->{topic}=$newTopic;
  $self->send(":$springHost TOPIC \&$self->{battle} :$newTopic");
}

sub fixUserCase {
  my $user=shift;
  $user='' unless(defined $user);
  return $user if($user eq $self->{login});
  if(! exists $self->{lobby}->{users}->{$user}) {
    my $lcUser=lc($user);
    return $self->{lowerCaseClients}->{$lcUser} if(exists $self->{lowerCaseClients}->{$lcUser});
  }
  return $user;
}

# Internal handlers and hooks #################################################

sub hNull {
}

sub hNick {
  my (undef,$nick)=@_;
  if($nick =~ /^:(.*)$/) {
    $nick=$1;
    $self->send("NOTICE AUTH :*** Warning, your IRC client prefixed your nickname with ':'");
    $self->{simpleLog}->log("Removing ':' nickname prefix".logSuffix(),2);
  }
  if(defined $self->{login} && $self->{login} ne '') {
    if($self->{login} ne $nick) {
      $self->send(":$springHost NOTICE $self->{login} :Spring IRC Bridge doesn't support rename");
      $self->send(":$springHost 449 $self->{login} :Spring IRC Bridge doesn't support rename");
    }
    return;
  }
  $self->{login}=$nick;
  $self->{timestamps}->{connectAttempt}=0;
  if(defined $self->{ident}) {
    if(! defined $self->{password}) {
      $self->send("NOTICE AUTH :*** Authentication failed, you must provide your Spring lobby password as IRC password before sending USER command");
      $self->send(":$springHost 464 $self->{login} :Missing password");
      $self->hDisconnect('missing IRC password');
      return;
    }
    $self->{ircState}=1;
  }
}

sub hPass {
  my (undef,$pass)=@_;
  if($pass =~ /^:(.*)$/) {
    $pass=$1;
    $self->send("NOTICE AUTH :*** Warning, your IRC client prefixed your password with ':'");
    $self->{simpleLog}->log("Removing ':' password prefix".logSuffix(),2);
  }
  $self->{password}=$pass;
}

sub hUser {
  my (undef,$params)=@_;
  if($params =~ /^([^ ]+) /) {
    $self->{ident}=$1;
  }else{
    $self->send("NOTICE AUTH :*** Authentication failed, invalid ident");
    $self->hDisconnect('invalid IRC ident');
    return;
  }
  if(! defined $self->{password}) {
    $self->send("NOTICE AUTH :*** Authentication failed, you must provide your Spring lobby password as IRC password before sending USER command");
    if(defined $self->{login}) {
      $self->send(":$springHost 464 $self->{login} :Missing password");
    }else{
      $self->send(":$springHost 464 :Missing password");
    }
    $self->hDisconnect('missing IRC password');
    return;
  }
  $self->{ircState}=1 if(defined $self->{login});
}

sub hJoin {
  my (undef,$channelsAndKeys)=@_;
  my ($channels,$keys)=split(/ +/,$channelsAndKeys);
  $keys="" unless(defined $keys);
  my @chans=split(/,/,$channels);
  my @ks=split(/,/,$keys);
  foreach my $chan (@chans) {
    my $k=shift(@ks);
    $chan=$1 if($chan =~ /^\#(\&.+)$/);
    $k=$1 if(defined $k && $k =~ /^\:(.+)$/);
    $self->{userModes}->{$chan}={};
    if($chan =~ /^\#(.+)$/) {
      $chan=$1;
      if(defined $k) {
        $self->{lobby}->sendCommand(["JOIN",$chan,$k]);
      }else{
        $self->{lobby}->sendCommand(["JOIN",$chan]);
      }
    }elsif($chan eq '&debug') {
      $self->{isInDebug}=1;
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} JOIN \&debug");
      $self->send(":$springHost 332 $self->{login} \&debug :IRC bridge special channel for network traffic debug");
      $self->send(":$springHost 333 $self->{login} \&debug IrcBridge 0");
      $self->send(":$springHost 353 $self->{login} = \&debug :$self->{login}");
      $self->send(":$springHost 366 $self->{login} \&debug :End of /NAMES list.");
    }elsif($chan eq '&debug_lobby') {
      $self->{isInDebugLobby}=1;
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} JOIN \&debug_lobby");
      $self->send(":$springHost 332 $self->{login} \&debug_lobby :IRC bridge special channel for Lobby traffic debug");
      $self->send(":$springHost 333 $self->{login} \&debug_lobby IrcBridge 0");
      $self->send(":$springHost 353 $self->{login} = \&debug_lobby :$self->{login}");
      $self->send(":$springHost 366 $self->{login} \&debug_lobby :End of /NAMES list.");
    }elsif($chan eq '&debug_irc') {
      $self->{isInDebugIrc}=1;
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} JOIN \&debug_irc");
      $self->send(":$springHost 332 $self->{login} \&debug_irc :IRC bridge special channel for IRC traffic debug");
      $self->send(":$springHost 333 $self->{login} \&debug_irc IrcBridge 0");
      $self->send(":$springHost 353 $self->{login} = \&debug_irc :$self->{login}");
      $self->send(":$springHost 366 $self->{login} \&debug_irc :End of /NAMES list.");
    }elsif($chan eq '&local') {
      $self->{isInLocal}=1;
      $self->{userModes}->{'&local'}={};
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} JOIN \&local");
      $self->send(":$springHost 332 $self->{login} \&local :IRC bridge special channel containing all Spring clients");
      $self->send(":$springHost 333 $self->{login} \&local IrcBridge 0");
      my @users;
      foreach my $u (keys %{$self->{lobby}->{users}}) {
        my $userString=$u;
        my $p_uStatus=$self->{lobby}->{users}->{$u}->{status};
        if($p_uStatus->{access}) {
          if($p_uStatus->{bot}) {
            $self->{userModes}->{'&local'}->{$u}='!';
            $userString="!$u";
          }else{
            $self->{userModes}->{'&local'}->{$u}='o';
            $userString="\@$u";
          }
        }elsif($p_uStatus->{bot}) {
          $self->{userModes}->{'&local'}->{$u}='h';
          $userString="\%$u";
        }elsif($self->{lobby}->{users}->{$u}->{status}->{inGame}) {
          $self->{userModes}->{'&local'}->{$u}='v';
          $userString="+$u";
        }else{
          $self->{userModes}->{'&local'}->{$u}='';
        }
        push(@users,$userString);
        if($#users > 20) {
          my $listString=join(" ",@users);
          $self->send(":$springHost 353 $self->{login} = \&local :$listString");
          @users=();
        }
      }
      if(@users) {
        my $listString=join(" ",@users);
        $self->send(":$springHost 353 $self->{login} = \&local :$listString");
      }
      $self->send(":$springHost 366 $self->{login} \&local :End of /NAMES list.");
    }elsif($chan =~ /^\&(\d+)$/) {
      if(defined $k) {
        $self->{lobby}->sendCommand(["JOINBATTLE",$1,$k]);
      }else{
        $self->{lobby}->sendCommand(["JOINBATTLE",$1]);
      }
      $self->{pendingBattle}=$1;
    }elsif($chan =~ /^\&([^ ]+)$/) {
      my $joinedUser=$1;
      if(exists $self->{userBattles}->{$joinedUser}) {
        if(defined $k) {
          $self->{lobby}->sendCommand(["JOINBATTLE",$self->{userBattles}->{$joinedUser},$k]);
        }else{
          $self->{lobby}->sendCommand(["JOINBATTLE",$self->{userBattles}->{$joinedUser}]);
        }
        $self->{pendingBattle}=$self->{userBattles}->{$joinedUser};
      }else{
        $self->send(":$springHost 479 $self->{login} \&$joinedUser :Cannot join battle (user $joinedUser not in battle)");
      }
    }
  }
}

sub hList {
  my (undef,$param)=@_;
  $self->send(":$springHost 321 $self->{login} Channel :Users  Name");
  if(defined $param && $param eq "battles") {
    cbEndOfChannels();
  }else{
    $self->{lobby}->sendCommand(["CHANNELS"]);
  }
}

sub hPart {
  my (undef,$chanAndReason)=@_;
  my ($chan,$reason)=($chanAndReason,undef);
  if($chanAndReason =~ /^([^\s]+)\s+(.+)$/) {
    $chan=$1;
    $reason=$2;
    $reason=$1 if($reason =~ /^:(.*)$/);
  }
  if($chan =~ /^\#([^\s]+)/) {
    $chan=$1; 
    $self->{lobby}->sendCommand(["LEAVE",$chan]);
    $self->send(":$self->{login}!~$self->{ident}\@$self->{host} PART $chanAndReason");
    delete $self->{userModes}->{"\#$chan"};
  }elsif($chan =~ /^\&debug/) {
    $self->{isInDebug}=0;
    $self->send(":$self->{login}!~$self->{ident}\@$self->{host} PART $chanAndReason");
  }elsif($chan =~ /^\&debug_lobby/) {
    $self->{isInDebugLobby}=0;
    $self->send(":$self->{login}!~$self->{ident}\@$self->{host} PART $chanAndReason");
  }elsif($chan =~ /^\&debug_irc/) {
    $self->{isInDebugIrc}=0;
    $self->send(":$self->{login}!~$self->{ident}\@$self->{host} PART $chanAndReason");
  }elsif($chan =~ /^\&local/) {
    $self->{isInLocal}=0;
    delete $self->{userModes}->{'&local'};
    $self->send(":$self->{login}!~$self->{ident}\@$self->{host} PART $chanAndReason");
  }elsif($chan =~ /^\&(\d+)$/) {
    if(defined $self->{battle} && $self->{battle} == $1) {
      $self->{lobby}->sendCommand(["LEAVEBATTLE"]);
    }
  }
}

sub hIsOn {
  my (undef,$params)=@_;
  if(! defined $params || $params =~ /^ *$/) {
    $self->send(":$springHost 461 $self->{login}");
    return;
  }
  my @paramsArray=split(/ /,$params);
  my @onlineUsers;
  foreach my $nick (@paramsArray) {
    $nick=fixUserCase($nick);
    push(@onlineUsers,$nick) if(exists $self->{lobby}->{users}->{$nick});
  }
  my $onlineUsersString=join(' ',@onlineUsers);
  $self->send(":$springHost 303 $self->{login} :$onlineUsersString");
}

sub hWhois {
  my (undef,$nick)=@_;
  $nick=$1 if($nick =~ /^([^ ]+)/);
  $nick=fixUserCase($nick);
  if(exists $self->{lobby}->{users}->{$nick}) {
    my @ranks=("Newbie","Beginner","Average","Above average","Experienced","Highly experienced","Veteran","Ghost");
    my $p_userData=$self->{lobby}->{users}->{$nick};
    if($p_userData->{status}->{away}) {
      $self->send(":$springHost 301 $self->{login} $nick :away");
    }
    my $additionalInfoString="";
    $additionalInfoString=", in-game" if($p_userData->{status}->{inGame});
    $self->send(":$springHost 311 $self->{login} $nick $p_userData->{country}_$p_userData->{cpu} $p_userData->{accountId}.$springHost * :$nick ($ranks[$p_userData->{status}->{rank}]$additionalInfoString)");
    $self->send(":$springHost 312 $self->{login} $nick $springHost :Spring Lobby Server");
    if($p_userData->{status}->{access}) {
      $self->send(":$springHost 313 $self->{login} $nick :is a Spring moderator");
    }
    if(exists $self->{userBattles}->{$nick}) {
      my $battlePrefix='';
      if($self->{lobby}->{battles}->{$self->{userBattles}->{$nick}}->{founder} eq $nick) {
        $battlePrefix='.';
      }else{
        my $p_uStatus=$self->{lobby}->{users}->{$nick}->{status};
        if($p_uStatus->{access}) {
          if($p_uStatus->{bot}) {
            $battlePrefix='!';
          }else{
            $battlePrefix='@';
          }
        }elsif($p_uStatus->{bot}) {
          $battlePrefix='%';
        }
      }
      $self->send(":$springHost 319 $self->{login} $nick :$battlePrefix\&$self->{userBattles}->{$nick} $battlePrefix\&$self->{lobby}->{battles}->{$self->{userBattles}->{$nick}}->{founder}");
    }
  }else{
    $self->send(":$springHost 401 $self->{login} $nick :No such nick");
  }
  $self->send(":$springHost 318 $self->{login} $nick :End of /WHOIS list.");
}

sub hWho {
  my (undef,$name)=@_;
  my @ranks=("Newbie","Beginner","Average","Above average","Experienced","Highly experienced","Veteran","Ghost");
  if($name =~ /^\&(\d+)/) {
    my $battle=$1;
    if(exists $self->{lobby}->{battles}->{$battle}) {
      foreach my $u (@{$self->{lobby}->{battles}->{$battle}->{userList}}) {
        my $p_userData=$self->{lobby}->{users}->{$u};
        my $userString="$p_userData->{country}_$p_userData->{cpu} $p_userData->{accountId}.$springHost $springHost $u ";
        if($p_userData->{status}->{away}) {
          $userString.='G';
        }else{
          $userString.='H';
        }
        if($p_userData->{status}->{access}) {
          $userString.='*';
        }
        if($u eq $self->{lobby}->{battles}->{$battle}->{founder}) {
          $userString.='.';
        }elsif($p_userData->{status}->{access}) {
          if($p_userData->{status}->{bot}) {
            $userString.='!';
          }else{
            $userString.='@';
          }
        }elsif($p_userData->{status}->{bot}) {
          $userString.='%';
        }else{
          if(defined $self->{battle} && $self->{battle} == $battle) {
            my $p_uBattleData=$self->{lobby}->{battle}->{users}->{$u};
            $userString.="+" if(defined $p_uBattleData->{battleStatus} && $p_uBattleData->{battleStatus}->{mode});
          }
        }
        my $additionalInfoString="";
        $additionalInfoString=", in-game" if($p_userData->{status}->{inGame});
        $userString.=" :1 $u ($ranks[$p_userData->{status}->{rank}]$additionalInfoString)";
        $self->send(":$springHost 352 $self->{login} \&$battle $userString");
      }
    }
    $self->send(":$springHost 315 $self->{login} \&$battle :End of /WHO list.");
  }else{
    my $p_users={};
    if($name =~ /^\#([^ ]+)/) {
      my $chan=$1;
      $p_users=$self->{lobby}->{channels}->{$chan} if(exists $self->{lobby}->{channels}->{$chan});
      $name="\#$chan";
    }elsif($name eq '&local') {
      $p_users=$self->{lobby}->{users};
    }
    foreach my $u (keys %{$p_users}) {
      my $p_userData=$self->{lobby}->{users}->{$u};
        my $userString="$p_userData->{country}_$p_userData->{cpu} $p_userData->{accountId}.$springHost $springHost $u ";
      if($p_userData->{status}->{away}) {
        $userString.='G';
      }else{
        $userString.='H';
      }
      if($p_userData->{status}->{access}) {
        $userString.='*';
        if($p_userData->{status}->{bot}) {
          $userString.='!';
        }else{
          $userString.='@';
        }
      }elsif($p_userData->{status}->{bot}) {
        $userString.='%';
      }elsif($p_userData->{status}->{inGame}) {
        $userString.='+';
      }
      my $additionalInfoString="";
      $additionalInfoString=", in-game" if($p_userData->{status}->{inGame});
      $userString.=" :1 $u ($ranks[$p_userData->{status}->{rank}]$additionalInfoString)";
      $self->send(":$springHost 352 $self->{login} $name $userString");
    }
    $self->send(":$springHost 315 $self->{login} $name :End of /WHO list.");
  }
}

sub hPing {
  my (undef,$id)=@_;
  $self->send("PONG $id");
}

sub hQuit {
  my (undef,$reason)=@_;
  if(defined $reason && $reason =~ /^:(.+)$/) {
    $reason=$1;
  }else{
    $reason='normal quit';
  }
  $self->hDisconnect($reason);
}

sub dumpUserModes {
  if(! open(USERMODES,">modes_$self->{login}.dat")) {
    $self->{simpleLog}->log("Unable to write user modes into file \"modes_$self->{login}.dat\"".logSuffix(),1);
    return;
  }
  print USERMODES "statusMode:$self->{statusMode}\nwallopMode:$self->{wallopMode}\nircTimeout:$self->{ircTimeout}\nlobbyTimeout:$self->{lobbyTimeout}";
  close(USERMODES);
}

sub loadUserModes {
  if(-f "modes_$self->{login}.dat") {
    if(! open(USERMODES,"<modes_$self->{login}.dat")) {
      $self->{simpleLog}->log("Unable to read user modes from file \"modes_$self->{login}.dat\"".logSuffix(),1);
    }else{
      my %tmpModes;
      while(<USERMODES>) {
        my $modeLine=$_;
        chomp($modeLine);
        if($modeLine =~ /^([^:]+):(.+)$/) {
          $tmpModes{$1}=$2;
        }else{
          $self->{simpleLog}->log("Invalid line in user modes file: \"$modeLine\"".logSuffix(),1);
        }
      }
      close(USERMODES);
      return \%tmpModes;
    }
  }
  return {};
}

sub hMode {
  my (undef,$params)=@_;
  my @paramsArray=split(/ /,$params);
  return unless(@paramsArray && $self->{lobbyState} > 2);
  if($#paramsArray > 0) {
    if($paramsArray[1] eq "+b" || $paramsArray[1] eq 'b') {
      $self->send(":$springHost 368 $self->{login} $paramsArray[0] :End of Channel Ban List");
    }elsif($paramsArray[1] eq "+i") {
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} +i");
    }elsif($paramsArray[1] eq "+s") {
      $self->{statusMode}=1;
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} +s");
      dumpUserModes();
    }elsif($paramsArray[1] eq "-s") {
      $self->{statusMode}=0;
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} -s");
      dumpUserModes();
    }elsif($paramsArray[1] eq "+w") {
      $self->{wallopMode}=1;
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} +w");
      dumpUserModes();
    }elsif($paramsArray[1] eq "-w") {
      $self->{wallopMode}=0;
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} -w");
      dumpUserModes();
    }elsif($paramsArray[1] eq "+ws") {
      $self->{wallopMode}=1;
      $self->{statusMode}=1;
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} +ws");
      dumpUserModes();
    }elsif($paramsArray[1] eq "t") {
      if($#paramsArray==1) {
        $self->{ircTimeout}=120;
      }elsif($paramsArray[2] =~ /^(\d+)$/) {
        my $newTimeout=$1;
        $self->{ircTimeout}=$newTimeout if($newTimeout > 4 && $newTimeout < 600);
      }
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} t $self->{ircTimeout}");
      dumpUserModes();
    }elsif($paramsArray[1] eq "T") {
      if($#paramsArray==1) {
        $self->{lobbyTimeout}=60;
      }elsif($paramsArray[2] =~ /^(\d+)$/) {
        my $newTimeout=$1;
        $self->{lobbyTimeout}=$newTimeout if($newTimeout > 15 && $newTimeout < 600);
      }
      $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} T $self->{lobbyTimeout}");
      dumpUserModes();
    }else{
      $self->{simpleLog}->log("Ignoring unknown MODE request \"$params\"".logSuffix(),2);
    }
  }elsif($paramsArray[0] =~ /^\&(\d+)$/) {
    my $battle=$1;
    if(exists $self->{lobby}->{battles}->{$battle}) {
      my $iMode="";
      $iMode='i' if(defined $self->{battle} && $self->{battle} == $battle && $self->{battleData}->{inviteOnly});
      $self->send(":$springHost 324 $self->{login} $paramsArray[0] +tnCN${iMode}l $self->{lobby}->{battles}->{$battle}->{maxPlayers}");
    }else{
      $self->{simpleLog}->log("Ignoring MODE request for unknown battle: \"$battle\"".logSuffix(),2);
    }
  }else{
    $self->send(":$springHost 324 $self->{login} $paramsArray[0] +tnCN");
  }
}

sub hTopic {
  my (undef,$chanAndTopic)=@_;
  if($chanAndTopic =~ /^\#([^ ]+) :(.+)$/) {
    my ($chan,$topic)=($1,$2);
    $self->{lobby}->sendCommand(["CHANNELTOPIC",$chan,$topic]);
  }else{
    $self->{simpleLog}->log("Ignoring invalid TOPIC command parameters \"$chanAndTopic\"".logSuffix(),1);
  }
}

sub hPrivMsg {
  my (undef,$destAndMsg)=@_;
  if($destAndMsg =~ /^([^ ]+) :(.*)$/) {
    my ($dest,$msg)=($1,$2);
    if($dest =~ /^\#(.+)$/) {
      $dest=$1;
      if(exists $self->{lobby}->{channels}->{$dest}) {
        if($msg =~ /^ACTION (.*)$/) {
          $msg=$1;
          if($msg ne '') {
            $self->{lobby}->sendCommand(["SAYEX",$dest,$msg]);
          }
        }else{
          if($msg ne '') {
            $self->{lobby}->sendCommand(["SAY",$dest,$msg]);
          }
        }
      }else{
        $self->{simpleLog}->log("Ignoring invalid PRIVMSG command (not in this channel) \"$destAndMsg\"".logSuffix(),1);
        $self->send(":$springHost 404 $self->{login} \#$dest :Cannot send to channel");
      }
    }elsif($dest =~ /^\&(\d+)$/) {
      $dest=$1;
      if(defined $self->{battle} && $self->{battle} == $dest) {
        if($msg =~ /^ACTION (.*)$/) {
          $msg=$1;
          if($msg ne '') {
            $self->{lobby}->sendCommand(["SAYBATTLEEX",$msg]);
          }
        }else{
          if($msg ne '') {
            $self->{lobby}->sendCommand(["SAYBATTLE",$msg]);
          }
        }
      }else{
        $self->{simpleLog}->log("Ignoring invalid PRIVMSG command (not in this battle) \"$destAndMsg\"".logSuffix(),1);
        $self->send(":$springHost 404 $self->{login} \&$dest :Cannot send to channel");
      }
    }elsif($dest eq '&local') {
      my @tokens=split(' ',$msg);
      $self->{lobby}->sendCommand(\@tokens);
    }else{
      $msg=$1 if($msg =~ /^ACTION (.*)$/);
      $dest=fixUserCase($dest);
      if(exists $self->{lobby}->{users}->{$dest}) {
        if($msg ne '') {
          $self->{lobby}->sendCommand(["SAYPRIVATE",$dest,$msg]);
        }
      }else{
        $self->{simpleLog}->log("Ignoring invalid PRIVMSG command (user not found) \"$destAndMsg\"".logSuffix(),1);
        $self->send(":$springHost 401 $self->{login} $dest :No such nick");
      }
    }
  }else{
    $self->{simpleLog}->log("Ignoring invalid PRIVMSG command parameters \"$destAndMsg\"".logSuffix(),1);
  }
}

sub hNotice {
  my (undef,$destAndMsg)=@_;
  my $quotedLogin=quotemeta($self->{login});
  if($destAndMsg =~ /^$quotedLogin :(.+)$/) {
    my $msg=$1;
    $self->send(":$self->{login}!~$self->{ident}\@$self->{host} NOTICE $self->{login} :$msg");
  }else{
    $self->{simpleLog}->log("Ignoring invalid NOTICE command parameters \"$destAndMsg\"".logSuffix(),1);
  }
}

sub hAway {
  my (undef,$reason)=@_;
  return unless($self->{lobbyState} > 3);
  my %clientStatus = %{$self->{lobby}->{users}->{$self->{login}}->{status}};
  if(defined $reason && $reason ne "" && $reason ne ":") {
    $clientStatus{away}=1;
    $self->send(":$springHost 306 $self->{login} :You have been marked as being away");
  }else{
    $clientStatus{away}=0;
    $self->send(":$springHost 305 $self->{login} :You are no longer marked as being away");
  }
  $self->{lobby}->sendCommand(["MYSTATUS",$self->{lobby}->marshallClientStatus(\%clientStatus)]);
}

sub cbConnectTimeout {
  $self->{lobbyState}=0;
  $self->{simpleLog}->log("Timeout while connecting to lobby server".logSuffix(),2);
}

sub cbLobbyConnect {
  $self->{lobbyState}=2;
  $self->{timestamps}->{lobbyPong}=time;

  $self->{lobby}->addCallbacks({MOTD => \&cbMotd,
                                CHANNELTOPIC => \&cbChannelTopic,
                                NOCHANNELTOPIC => \&cbNoChannelTopic,
                                LOGININFOEND => \&cbLoginInfoEnd,
                                JOIN => \&cbJoin,
                                JOINFAILED => \&cbJoinFailed,
                                ADDUSER => \&cbAddUser,
                                SAID => \&cbSaid,
                                CHANNELMESSAGE => \&cbChannelMessage,
                                SERVERMSG => \&cbServerMsg,
                                SAIDEX => \&cbSaidEx,
                                SAIDPRIVATE => \&cbSaidPrivate,
                                CHANNEL => \&cbChannel,
                                ENDOFCHANNELS => \&cbEndOfChannels,
                                SAIDBATTLE => \&cbSaidBattle,
                                SAIDBATTLEEX => \&cbSaidBattleEx,
                                CLIENTSTATUS => \&cbClientStatus,
                                JOINBATTLE => \&cbJoinBattle,
                                JOINBATTLEFAILED => \&cbJoinBattleFailed,
                                REQUESTBATTLESTATUS => \&cbRequestBattleStatus,
                                CLIENTBATTLESTATUS => \&cbClientBattleStatus,
                                JOINEDBATTLE => \&cbJoinedBattle,
                                LEFTBATTLE => \&cbLeftBattle,
                                BROADCAST => \&cbBroadcast,
                                BATTLEOPENED => \&cbBattleOpened,
                                BATTLECLOSED => \&cbBattleClosed,
                                UPDATEBATTLEINFO => \&cbUpdateBattleInfo,
                                JOINED => \&cbJoined,
                                LEFT => \&cbLeft,
                                FORCELEAVECHANNEL => \&cbForceLeaveChannel,
                                RING => \&cbRing});

  $self->{lobby}->addPreCallbacks({REMOVEUSER => \&cbPreRemoveUser});

  $self->{lobby}->sendCommand(["LOGIN",$self->{login},$self->{lobby}->marshallPasswd($self->{password}),0,$self->{ircSock}->peerhost(),"SpringIrcBridge v0.4",0,'a et'],
                              {ACCEPTED => \&cbLoginAccepted,
                               DENIED => \&cbLoginDenied},
                              \&cbLoginTimeout);
}

sub cbLoginDenied {
  my (undef,$reason)=@_;
  if($reason =~ /^Already logged in/) {
    $self->send(":$springHost 433 * $self->{login} :Nickname is already in use.");
    $self->{login}='';
    $self->{lobbyState}=0;
    $self->{lobby}->disconnect();
  }else{
    $self->send("NOTICE AUTH :*** Login denied on lobby server ($reason)");
    $self->send(":$springHost 464 $self->{login} :$reason");
    $self->hDisconnect("login denied on lobby server: $reason");
  }
}

sub cbLoginTimeout {
  $self->send("NOTICE AUTH :*** Unable to login on lobby server (timeout)");
  $self->{simpleLog}->log("Unable to login on lobby server (timeout)".logSuffix(),3);
  $self->{lobby}->disconnect();
  $self->{lobbyState}=0;
}

sub cbLoginAccepted {
  $self->{lobbyState}=3;
  my $p_userModes=loadUserModes();
  for my $modeName ('statusMode','wallopMode','ircTimeout','lobbyTimeout') {
    $self->{$modeName}=$p_userModes->{$modeName} if(exists $p_userModes->{$modeName});
  }
  $self->send(":$springHost 001 $self->{login} :Welcome to the Spring IRC Bridge, $self->{login}");
  $self->send(":$springHost 002 $self->{login} :Your host is $self->{host}, running version 0.1");
  $self->send(":$springHost 003 $self->{login} :This server was created Sat Mar 15 2008 at 06:40:40 CET");
  $self->send(":$springHost 004 $self->{login} $springHost 0.1 dioswkgxRXInP !biklmnohpstvrDcCNuMT bklov");
  $self->send(":$springHost 005 $self->{login} WHOX MODES=6 MAXCHANNELS=20 MAXBANS=45 NICKLEN=15 :are supported by this server");
  $self->send(":$springHost 005 $self->{login} MAXNICKLEN=15 TOPICLEN=500 AWAYLEN=160 KICKLEN=250 CHANNELLEN=200 MAXCHANNELLEN=200 CHANTYPES=#&! PREFIX=(!uohv)!.@%+ CHANMODES=b,k,l,imnpstrDducCNMT CASEMAPPING=rfc1459 NETWORK=SpringLobby :are supported by this server");
  $self->send(":$springHost 251 $self->{login} :There are $self->{nbClient} users and 0 invisible on 1 servers");
  $self->send(":$springHost 252 $self->{login} 0 :operator(s) online");
  $self->send(":$springHost 253 $self->{login} 0 :unknown connection(s)");
  $self->send(":$springHost 254 $self->{login} 2 :channels formed");
  $self->send(":$springHost 255 $self->{login} :I have $self->{nbClient} clients and 1 servers");
  $self->send(":$springHost 375 $self->{login} :- $springHost Message of the Day - ");
}

sub cbMotd {
  my (undef,$motdLine)=@_;
  $motdLine="" unless(defined $motdLine);
  $self->send(":$springHost 372 $self->{login} :- $motdLine");
}

sub applyChannelJoin {
  my $chan=$self->{pendingChan};
  $self->{pendingChan}=undef;

  if(! exists $self->{lobby}->{channels}->{$chan}) {
    $self->{simpleLog}->log("applyChannelJoin() called for an unknown chan \"$chan\" !".logSuffix(),1);
    return;
  }

  my @users;
  foreach my $u (keys %{$self->{lobby}->{channels}->{$chan}}) {
    my $userString=$u;
    my $p_uStatus=$self->{lobby}->{users}->{$u}->{status};
    if($p_uStatus->{access}) {
      if($p_uStatus->{bot}) {
        $self->{userModes}->{"\#$chan"}->{$u}='!';
        $userString="!$u";
      }else{
        $self->{userModes}->{"\#$chan"}->{$u}='o';
        $userString="\@$u";
      }
    }elsif($p_uStatus->{bot}) {
      $self->{userModes}->{"\#$chan"}->{$u}='h';
      $userString="\%$u";
    }elsif($self->{lobby}->{users}->{$u}->{status}->{inGame}) {
      $self->{userModes}->{"\#$chan"}->{$u}='v';
      $userString="+$u";
    }else{
      $self->{userModes}->{"\#$chan"}->{$u}='';
    }
    push(@users,$userString);
    if($#users > 20) {
      my $listString=join(" ",@users);
      $self->send(":$springHost 353 $self->{login} = \#$chan :$listString");
      @users=();
    }
  }
  if(@users) {
    my $listString=join(" ",@users);
    $self->send(":$springHost 353 $self->{login} = \#$chan :$listString");
  }
  $self->send(":$springHost 366 $self->{login} \#$chan :End of /NAMES list.");
}

sub cbChannelTopic {
  my (undef,$chan,$user,$time,$topic)=@_;
  if(defined $self->{pendingChan} && $chan eq $self->{pendingChan}) {
    $self->send(":$self->{login}!~$self->{ident}\@$self->{host} JOIN \#$chan");
    $self->send(":$springHost 332 $self->{login} \#$chan :$topic");
    $self->send(":$springHost 333 $self->{login} \#$chan $user $time");
    applyChannelJoin();
  }else{
    my $userMask=$user;
    if(exists $self->{lobby}->{users}->{$user}) {
      my $p_userData=$self->{lobby}->{users}->{$user};
      $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
    }
    $self->send(":$userMask TOPIC \#$chan :$topic");
  }
}

sub cbNoChannelTopic {
  my (undef,$chan)=@_;
  $chan=$self->{pendingChan} if(! defined $chan && defined $self->{pendingChan});
  if(defined $self->{pendingChan} && $chan eq $self->{pendingChan}) {
    $self->send(":$self->{login}!~$self->{ident}\@$self->{host} JOIN \#$chan");
    $self->send(":$springHost 331 $self->{login} \#$chan :No topic is set");
    applyChannelJoin();
  }else{
    $self->{simpleLog}->log("Received a NOCHANNELTOPIC for a channel we are not joining (\"$chan\") !".logSuffix(),1);
  }
}

sub cbLoginInfoEnd {
  $self->{lobbyState}=4;
  $self->send(":$springHost 376 $self->{login} :End of /MOTD command.");
  $self->send(":$springHost 221 $self->{login} +i");
  $self->send(":$self->{login}!~$self->{ident}\@$self->{host} MODE $self->{login} +i");
}

sub cbJoin {
  my (undef,$chan)=@_;
  $self->{pendingChan}=$chan;
}

sub cbJoinFailed {
  my (undef,$chan,$reason)=@_;
  $self->send(":$springHost 479 $self->{login} \#$chan :Cannot join channel ($reason)");
}

sub cbSaid {
  my (undef,$chan,$user,$msg)=@_;
  return if($user eq $self->{login});
  my $userMask=$user;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  $self->send(":$userMask PRIVMSG \#$chan :$msg");
}

sub cbSaidBattle {
  my (undef,$user,$msg)=@_;
  return if($user eq $self->{login});
  my $userMask=$user;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  $self->send(":$userMask PRIVMSG \&$self->{battle} :$msg");
}

sub cbSaidEx {
  my (undef,$chan,$user,$msg)=@_;
  return if($user eq $self->{login});
  my $userMask=$user;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  $self->send(":$userMask PRIVMSG \#$chan :ACTION $msg");
}

sub cbSaidBattleEx {
  my (undef,$user,$msg)=@_;
  return if($user eq $self->{login});
  my $userMask=$user;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  $self->send(":$userMask PRIVMSG \&$self->{battle} :ACTION $msg");
}

sub cbSaidPrivate {
  my (undef,$user,$msg)=@_;
  return if($user eq $self->{login});
  my $userMask=$user;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  $self->send(":$userMask PRIVMSG $self->{login} :$msg");
}

sub cbChannelMessage {
  my (undef,$chan,$msg)=@_;
  $self->send(":$springHost NOTICE \#$chan :$msg");
}

sub cbServerMsg {
  my (undef,$msg)=@_;
  if(($msg !~ /^\[broadcast to all admins\]/ && $msg !~ /^New registration of /) || $self->{wallopMode} != 0) {
    $self->send(":$springHost NOTICE $self->{login} :[SERVER MESSAGE] $msg");
  }
}

sub cbBroadcast {
  my (undef,$msg)=@_;
  $self->send(":$springHost NOTICE $self->{login} :[BROADCAST] $msg");
}

sub cbJoined {
  my (undef,$chan,$user)=@_;
  my $userMask=$user;
  my $mode;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
    if(exists $self->{userModes}->{"\#$chan"}) {
      $self->{userModes}->{"\#$chan"}->{$user}='';
    }else{
      $self->{simpleLog}->log("Received a JOINED message for a channel we are not in ($chan)!".logSuffix(),2);
    }
    if($p_userData->{status}->{access}) {
      if($p_userData->{status}->{bot}) {
        $mode='!';
      }else{
        $mode='o';
      }
    }elsif($p_userData->{status}->{bot}) {
      $mode='h';
    }elsif($p_userData->{status}->{inGame}) {
      $mode='v';
    }
  }
  $self->send(":$userMask JOIN \#$chan");
  if(defined $mode) {
    $self->send(":$springHost MODE \#$chan +$mode $user") unless($mode eq 'v' && $self->{statusMode} == 0);
    $self->{userModes}->{"\#$chan"}->{$user}=$mode if(exists $self->{userModes}->{"\#$chan"});
  }
}

sub cbLeft {
  my (undef,$chan,$user,$reason)=@_;
  my $userMask=$user;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  if(defined $reason) {
    if($reason =~ /^\s*kicked from channel\s*$/) {
      $self->send(":$springHost KICK \#$chan $user");
    }elsif($reason =~ /^\s*kicked from channel (.+)$/) {
      my $kickReason=$1;
      $self->send(":$springHost KICK \#$chan $user :$kickReason");
    }else{
      $self->{pendingQuit}->{$user}=$reason;
    }
  }else{
    $self->send(":$userMask PART \#$chan");
  }
  if($user eq $self->{login}) {
    delete $self->{userModes}->{"\#$chan"};
  }else{
    if(exists $self->{userModes}->{"\#$chan"}) {
      delete $self->{userModes}->{"\#$chan"}->{$user};
    }else{
      $self->{simpleLog}->log("Received a LEFT message for a channel we are not in ($chan)!".logSuffix(),2);
    }
  }
}

sub cbForceLeaveChannel {
  my (undef,$chan,$kicker,$reason)=@_;
  $reason='' unless(defined $reason && $reason ne 'None');

  $reason=" :$reason" if($reason ne '');
  my $userMask=$kicker;
  if(exists $self->{lobby}->{users}->{$kicker}) {
    my $p_userData=$self->{lobby}->{users}->{$kicker};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  $self->send(":$userMask KICK \#$chan $self->{login}$reason");

  delete $self->{userModes}->{"\#$chan"};
}

sub cbAddUser {
  my (undef,$user)=@_;
  if($self->{isInLocal}) {
    my $userMask=$user;
    if(exists $self->{lobby}->{users}->{$user}) {
      my $p_userData=$self->{lobby}->{users}->{$user};
      $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
      $self->{userModes}->{'&local'}->{$user}='';
    }
    $self->send(":$userMask JOIN \&local");
  }
  $self->{lowerCaseClients}->{lc($user)}=$user;
}

sub cbPreRemoveUser {
  my (undef,$user)=@_;
  my $userMask=$user;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  if(exists $self->{pendingQuit}->{$user}) {
    $self->send(":$userMask QUIT :$self->{pendingQuit}->{$user}");
    delete $self->{pendingQuit}->{$user};
  }elsif($self->{isInLocal}) {
    $self->send(":$userMask QUIT :");
    delete $self->{userModes}->{'&local'}->{$user};
  }
  delete $self->{userBattles}->{$user};
  delete $self->{lowerCaseClients}->{lc($user)};
}

sub hUserHost {
  my (undef,$user)=@_;
  $user=$self->{login} unless(defined $user);
  $user=fixUserCase($user);
  if($user eq $self->{login}) {
    $self->send(":$springHost 302 $self->{login} :$self->{login}=~$self->{ident}\@$self->{host}");
  }elsif(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $self->send(":$springHost 302 $self->{login} :$user=$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost");
  }else{
    $self->send(":$springHost 401 $self->{login} $user :No such nick");
  }
}

sub cbChannel {
  my (undef,$chan,$nb,@topicTokens)=@_;
  my $topic=join(" ",@topicTokens);
  $self->send(":$springHost 322 $self->{login} \#$chan $nb :$topic");
}

sub makeBattleString {
  my ($b,$fullMode)=@_;
  my $p_b=$self->{lobby}->{battles}->{$b};
  my $battleString="";
  if($fullMode) {
    if($p_b->{locked}) {
      $battleString="[4LOCKED1]-";
    }else{
      $battleString="[ 3OPEN1 ]-";
    }
  }
  if($self->{lobby}->{users}->{$p_b->{founder}}->{status}->{inGame}) {
    $battleString.="[6RUNNING1]-[";
  }else{
    $battleString.="[3WAITING1]-[";
  }
  if($p_b->{passworded}) {
    $battleString.="7PRIVATE1]";
  }else{
    $battleString.="3PUBLIC1 ]";
  }
  $battleString.="-[13REPLAY1]" if($p_b->{type});
  $battleString.=" |";
  my $nbUsers=$#{$p_b->{userList}}+1;
  if($fullMode) {
    my $nbPlayers=$nbUsers-$p_b->{nbSpec};
    if($nbPlayers >= $p_b->{maxPlayers}) {
      $battleString.="7 ";
    }elsif($nbPlayers > 0) {
      $battleString.="14 ";
    }else{
      $battleString.="15 ";
    }
    $battleString.="$nbPlayers+$p_b->{nbSpec}/";
  }else{
    $battleString.="7 ";
  }
  $battleString.="$p_b->{maxPlayers}1 | 10$p_b->{founder}1 | 12$p_b->{mod}1 |5 $p_b->{map}1 |2 $p_b->{title}1";
  if($fullMode) {
    my $usersString=join(",",@{$p_b->{userList}});
    $battleString.=" | $usersString";
  }
  return ($battleString,$nbUsers);
}

sub cbEndOfChannels {
  foreach my $b (keys %{$self->{lobby}->{battles}}) {
    my ($battleString,$nbUsers)=makeBattleString($b,1);
    $self->send(":$springHost 322 $self->{login} \&$b $nbUsers :$battleString");
  }
  my @lobbyUsers=keys %{$self->{lobby}->{users}};
  my $nbLobbyUsers=$#lobbyUsers+1;
  $self->send(":$springHost 322 $self->{login} \&debug_irc 0 :IRC bridge special channel for IRC traffic debug");
  $self->send(":$springHost 322 $self->{login} \&local $nbLobbyUsers :IRC bridge special channel containing all Spring clients");
  $self->send(":$springHost 323 $self->{login} :End of /LIST");
}

sub cbRequestBattleStatus {
  my $p_battleStatus = {
    side => 0,
    sync => 2,
    bonus => 0,
    mode => 0,
    team => 0,
    id => 0,
    ready => 1
  };
  my $p_color = {
    red => 255,
    green => 255,
    blue => 255
  };
  $self->{lobby}->sendCommand(["MYBATTLESTATUS",$self->{lobby}->marshallBattleStatus($p_battleStatus),$self->{lobby}->marshallColor($p_color)]);
}

sub cbJoinBattle {
  my (undef,$battle)=@_;
  $self->send(":$self->{login} JOIN \&$battle");
  $self->{battle}=$battle;
  my ($battleString)=makeBattleString($battle,0);
  $self->send(":$springHost 332 $self->{login} \&$battle :$battleString");
  $self->{battleData}={topic => $battleString,
                       inviteOnly => 0};
  my @users=($self->{login});
  foreach my $u (@{$self->{lobby}->{battles}->{$battle}->{userList}}) {
    my $userString=$u;
    my $p_uStatus=$self->{lobby}->{users}->{$u}->{status};
    if($u eq $self->{lobby}->{battles}->{$battle}->{founder}) {
      $self->{userModes}->{"\&$battle"}->{$u}='u';
      $userString=".$u";
    }elsif($p_uStatus->{access}) {
      if($p_uStatus->{bot}) {
        $self->{userModes}->{"\&$battle"}->{$u}='!';
        $userString="!$u";
      }else{
        $self->{userModes}->{"\&$battle"}->{$u}='o';
        $userString="\@$u";
      }
    }elsif($p_uStatus->{bot}) {
      $self->{userModes}->{"\&$battle"}->{$u}='h';
      $userString="\%$u";
    }else{
      my $p_uBattleData=$self->{lobby}->{battle}->{users}->{$u};
      if(defined $p_uBattleData->{battleStatus} && $p_uBattleData->{battleStatus}->{mode}) {
        $self->{userModes}->{"\&$battle"}->{$u}='v';
        $userString="+$u";
      }else{
        $self->{userModes}->{"\&$battle"}->{$u}='';
      }
    }
    push(@users,$userString);
    if($#users > 20) {
      my $listString=join(" ",@users);
      $self->send(":$springHost 353 $self->{login} = \&$battle :$listString");
      @users=();
    }
  }
  if(@users) {
    my $listString=join(" ",@users);
    $self->send(":$springHost 353 $self->{login} = \&$battle :$listString");
  }
  $self->send(":$springHost 366 $self->{login} \&$battle :End of /NAMES list.");
}

sub cbJoinBattleFailed {
  my (undef,$reason)=@_;
  my $bat="battle";
  $bat=$self->{pendingBattle} if(defined $self->{pendingBattle});
  $self->send(":$springHost 479 $self->{login} \&$self->{pendingBattle} :Cannot join battle ($reason)");
}

sub cbJoinedBattle {
  my (undef,$battleId,$user)=@_;
  if(defined $self->{battle} && $self->{battle} == $battleId) {
    my $userMask=$user;
    my $mode;
    $self->{userModes}->{"\&$battleId"}->{$user}='';
    if(exists $self->{lobby}->{users}->{$user}) {
      my $p_userData=$self->{lobby}->{users}->{$user};
      $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
      if($p_userData->{status}->{access}) {
        if($p_userData->{status}->{bot}) {
          $mode='!';
        }else{
          $mode='o';
        }
      }elsif($p_userData->{status}->{bot}) {
        $mode='h';
      }
    }
    $self->send(":$userMask JOIN \&$battleId");
    if(defined $mode) {
      $self->send(":$springHost MODE \&$battleId +$mode $user");
      $self->{userModes}->{"\&$battleId"}->{$user}=$mode;
    }
  }
  $self->{userBattles}->{$user}=$battleId;
}

sub cbLeftBattle {
  my (undef,$battleId,$user)=@_;
  if(defined $self->{battle} && $self->{battle} == $battleId) {
    my $userMask=$user;
    if(exists $self->{lobby}->{users}->{$user}) {
      my $p_userData=$self->{lobby}->{users}->{$user};
      $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
    }
    $self->send(":$userMask PART \&$battleId");
    if($user eq $self->{login}) {
      $self->{battle}=undef;
      $self->{battleData}={topic => undef,
                           inviteOnly => undef};
      delete $self->{userModes}->{"\&$battleId"};
    }else{
      delete $self->{userModes}->{"\&$battleId"}->{$user};
    }
  }
  delete $self->{userBattles}->{$user};
}

sub cbClientStatus {
  my (undef,$user)=@_;
  my $mode='';
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    if($p_userData->{status}->{access}) {
      if($p_userData->{status}->{bot}) {
        $mode='!';
      }else{
        $mode='o';
      }
    }elsif($p_userData->{status}->{bot}) {
      $mode='h';
    }elsif($p_userData->{status}->{inGame}) {
      $mode='v';
    }
  }
  foreach my $chan (keys %{$self->{userModes}}) {
    next unless(exists $self->{userModes}->{$chan}->{$user});
    if($chan eq '&local' || $chan =~ /^\#/) {
      next if($mode eq $self->{userModes}->{$chan}->{$user});
      if($mode eq '') {
        $self->send(":$springHost MODE $chan -$self->{userModes}->{$chan}->{$user} $user") unless($self->{userModes}->{$chan}->{$user} eq 'v' && $self->{statusMode} == 0);
      }else{
        $self->send(":$springHost MODE $chan +$mode $user") unless($mode eq 'v' && $self->{statusMode} == 0);
      }
      $self->{userModes}->{$chan}->{$user}=$mode;
    }elsif($chan =~ /^\&(\d+)$/) {
      my $battleId=$1;
      if($battleId != $self->{battle}) {
        $self->{simpleLog}->log("Cache for battle $battleId still in memory whereas we are in battle \"$self->{battle}\" !".logSuffix(),2);
        next;
      }
      my $battleMode='';
      $battleMode=$mode unless($mode eq 'v');
      if($user eq $self->{lobby}->{battles}->{$battleId}->{founder}) {
        $battleMode='u';
      }elsif($battleMode eq ''
             && exists $self->{lobby}->{battle}->{users}->{$user}
             && defined $self->{lobby}->{battle}->{users}->{$user}->{battleStatus}
             && $self->{lobby}->{battle}->{users}->{$user}->{battleStatus}->{mode}) {
        $battleMode='v';
      }
      next if($battleMode eq $self->{userModes}->{$chan}->{$user});
      if($battleMode eq '') {
        $self->send(":$springHost MODE $chan -$self->{userModes}->{$chan}->{$user} $user");
      }else{
        $self->send(":$springHost MODE $chan +$battleMode $user");
      }
      $self->{userModes}->{$chan}->{$user}=$battleMode;
    }
  }
  checkBattleTopic() if(defined $self->{battle} && $self->{lobby}->{battles}->{$self->{battle}}->{founder} eq $user);
}

sub cbClientBattleStatus {
  my (undef,$user)=@_;
  my $currentMode=$self->{userModes}->{"\&$self->{battle}"}->{$user};
  return unless($currentMode eq '' || $currentMode eq 'v');
  my $newMode='';
  my $p_uBattleData=$self->{lobby}->{battle}->{users}->{$user};
  $newMode='v' if(defined $p_uBattleData->{battleStatus} && $p_uBattleData->{battleStatus}->{mode});
  return if($newMode eq $currentMode);
  if($newMode eq 'v') {
    $self->send(":$springHost MODE \&$self->{battle} +v $user");
  }else{
    $self->send(":$springHost MODE \&$self->{battle} -v $user");
  }
  $self->{userModes}->{"\&$self->{battle}"}->{$user}=$newMode;
}

sub cbBattleOpened {
  my ($battleId,$founder)=($_[1],$_[4]);
  $self->{userBattles}->{$founder}=$battleId;
}

sub cbBattleClosed {
  my (undef,$battleId)=@_;
  if(defined $self->{battle} && $self->{battle}==$battleId) {
    $self->{battle}=undef;
    $self->{battleData}={topic => undef,
                         inviteOnly => undef};
    delete $self->{userModes}->{"\&$battleId"};
  }
  foreach my $user (keys %{$self->{userBattles}}) {
    delete $self->{userBattles}->{$user} if($self->{userBattles}->{$user} == $battleId);
  }
}

sub cbUpdateBattleInfo {
  my ($battleId,$locked)=($_[1],$_[3]);
  return unless(defined $self->{battle} && $self->{battle} == $battleId);
  checkBattleTopic();
  if($self->{battleData}->{inviteOnly} != $locked) {
    $self->{battleData}->{inviteOnly}=$locked;
    if($locked) {
      $self->send(":$springHost MODE \&$battleId +i");
    }else{
      $self->send(":$springHost MODE \&$battleId -i");
    }
  }
}

sub cbRing {
  my (undef,$user)=@_;
  my $userMask=$user;
  if(exists $self->{lobby}->{users}->{$user}) {
    my $p_userData=$self->{lobby}->{users}->{$user};
    $userMask.="!$p_userData->{country}_$p_userData->{cpu}\@$p_userData->{accountId}.$springHost";
  }
  $self->send(":$userMask NOTICE $self->{login} :[RING]");
}

1;
