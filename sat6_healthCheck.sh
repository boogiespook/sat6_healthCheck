#!/bin/sh

##############################
## Satellite 6 Health Check ##
##############################

######################
## Work In Progress 
##
## ToDo:
##
## - Add in remedial action for errors/warnings
## - Check all firewall reqs
## - Alter call depending on type (Sat6 or Capsule)
## - Add check for disconnected Sat6
##
######################

if [ "$EUID" -ne 0 ]
  then echo "Please run this script as root"
  exit 1
fi

warnings=0
errors=0
red=`tput setaf 1`
green=`tput setaf 2`
orange=`tput setaf 3`
reset=`tput sgr0`
hostname=$(hostname -f)
facter=$(which facter 2> /dev/null)
toInstall=""

## Make sure the various admin tools are available
MPSTAT=$(which mpstat >/dev/null 2>&1)
a=$?
if [[ $a != 0 ]]
then
  toInstall="$toInstall sysstat" 
fi

nmap=$(which nmap >/dev/null 2>&1)
a=$?
if [[ $a != 0 ]]
then
  toInstall="$toInstall nmap" 
fi

nslookup=$(which nslookup >/dev/null 2>&1)
a=$?
if [[ $a != 0 ]]
then
  toInstall="$toInstall bind-utils" 
fi

if [[ $toInstall != "" ]]
then
while true; do
    read -p "Certain utilities are required.  Ok to install $toInstall ?  (y/n) : " yn
    case $yn in
        [Yy]* ) yum -y install $toInstall; break;;
        [Nn]* ) echo " OK - health check stopped"; exit;;
        * ) echo "Please answer y or n.";;
    esac
done
fi

if [[ ! -f /root/.hammer/cli_config.yml ]]
then
    echo -e "A hammer config file has not been created.  This is used to interogate foreman.
Please do the following:
mkdir ~/.hammer
chmod 600 ~/.hammer
echo << EOF >> /root/.hammer/cli_config.yml
  :foreman:
       :host: 'https://$(hostname -f)'
       :username: 'admin'
       :password: 'password'

EOF"
exit 2
fi

TMPDIR="/tmp/sat6_check"

if [[ -d $TMPDIR ]]
then
  rm -rf $TMPDIR
fi
mkdir -p $TMPDIR
release=$(awk '{print $7}' /etc/redhat-release | cut -c1)
touch $TMPDIR/remedialAction

###############
## Functions ##
###############

function printOK {
  echo -e "${green}[OK]\t\t $1 ${reset}" | tee -a $TMPDIR/success
}

function printWarning {
  ((warnings=warnings+1))
  echo -e "${orange}[WARNING] $warnings\t $1 ${reset}" | tee -a $TMPDIR/warnings
}

function printError {
    ((errors=errors+1))
  echo -e "${red}[ERROR] $errors\t $1 ${reset}" | tee -a $TMPDIR/errors
}

function remedialAction {
  echo -e "$1" | tee -a $TMPDIR/remedialAction
}

function checkDNS {
host=$1
echo -e "
 + Checking DNS entries for $host"
#host=$(hostname -f)
forwardDNS=$(nslookup $host |  grep ^Name -A1 | awk '/^Address:/ {print $2}')
if [[ ! -z $forwardDNS ]]
then
  printOK "Forward DNS resolves to $forwardDNS"
else
  printError "Forward DNS does not resolve"

fi

reverseDNS=$(nslookup $forwardDNS | awk '/name/ {print $NF}' | rev | cut -c2- | rev)
if [[ ! -z $reverseDNS ]]
then
  printOK "Reverse DNS resolves to $reverseDNS"
else
  printError "Reverse DNS not resolvable for $forwardDNS"
fi

if [[ $host == $reverseDNS ]]
then
  printOK "Foreward and reverse DNS match"
else
  printError "Forward and reverse DNS do not match for $host / $reverseDNS"
fi
echo
}


function checkSubscriptions {
# Check current subscriptions
echo -e "
#######################
  Subcription Details
#######################
+ Checking enabled repositories (this could take some time)"
subscription-manager repos --list-enabled > ${TMPDIR}/repos
grep "^Repo Name" /tmp/sat6_check/repos 
sat6Version=$(awk '/Satellite/ {print $6}' /tmp/sat6_check/repos)
if [[ -z $sat6Version ]]
 then
    printWarning "Unable to ascertain a valid Satellite repository?"
 else
    printOK " -  Repository installed for Satellite version $sat6Version"
fi
}

function getType {
upstream=$(awk '/^hostname/ {print $3}' /etc/rhsm/rhsm.conf )
if [[ $upstream == "subscription.rhn.redhat.com" ]]
then
   # Connected Satellite Server
   printOK "This system is registered to $upstream which indicates it is a Satellite server" 
   TYPE="Satellite"
else
  # Satellite Capsule?
  if [[ $upstream == $hostname ]]
  then
    echo -e "This system is registered to itself ($hostname)"
    TYPE="Satellite"
  else
    TYPE="Capsule"
    echo "** This script only currently runs on Satellite servers not capsules.  A capsule version is currently being writted **"
    echo 3
  fi
fi
}

function checkGeneralSetup {
echo -e "
#######################################
    Satellite 6 Health Check Report 
#######################################

 + System Details:
 - Hostname         : $(hostname)
 - IP Address       : $(ip -4 -o a | grep -v "127.0.0" | awk '{print $4}')
 - Kernel Version   : $(uname -r)
 - Uptime           :$(uptime | sed 's/.*up \([^,]*\), .*/\1/')
 - Last Reboot Time : $(who -b | awk '{print $3,$4}')
 - Red Hat Release  : $(cat /etc/redhat-release)"

cpus=`lscpu | grep -e "^CPU(s):" | cut -f2 -d: | awk '{print $1}'`
i=0

echo " + CPU: %usr"
echo "   ---------"
while [ $i -lt $cpus ]
do
  echo " - CPU$i : `mpstat -P ALL | awk -v var=$i '{ if ($3 == var ) print $4 }' `"
  let i=$i+1
done
echo
echo -e "
####################
## Checking umask ##
####################"

umask=$(umask)
if [[ $umask -ne "0022" ]]
then
  printWarning "Umask is set to $umask which could cause problems with puppet module permissions.\n Recommend setting umask to 0022"
  else
  printOK "Umask is set to 00222"
fi

}


function checkNetworkConnection {
echo -e "
#######################
## Connection Status ##
#######################
"
# Connection to cdn.redhat.com
echo " + Checking connection to cdn.redhat.com"
ms=$(ping -c5 cdn.redhat.com | awk -F"/" '/^rtt/ {print $5}')
echo " -  Complete.  Average was $ms ms"
}

function checkSELinux {
echo " + Checking SELinux"
selinux=$(getenforce)
if [[ $selinux != "Enforcing" ]]
  then
    printWarning "SELinux is currently in $selinux mode. Enforcing is recommended by Red Hat"
  else
    printOK "SELinux is running in Enforcing mode."
fi
}

function checkService {
service=$1
echo " - Checking status of ${service}"
if (( $release >= 7 ))
  then
     ## Is it running?
     running=$(systemctl is-active ${service} 2> /dev/null)
     if [[ $running == "active" ]]
       then
	  printOK "${service} is running"
	  if [[ ${service} == "ntpd" ]]
	  then
	      echo " + NTP Servers:"
	      awk '/^server/ {print $2}' /etc/ntp.conf
	  fi
       else
 	  printError "${service} is not running"
 	  remedialAction "systemctl start ${service}"
     fi
     
     ## Is it enabled?
     enabled=$(systemctl is-enabled ${service} 2> /dev/null)
     if [[ $enabled == "enabled" ]]
       then
	  printOK "${service} is enabled"
       else
	 printWarning "${service} is not enabled to start on boot"
	 remedialAction "systemctl enable ${service}"
     fi
  else
  ## TO DO
  echo "Do the above for RHEL6 + iptables"
     ## iptables
fi
}

function checkOSupdates {
echo " + Checking for OS updates"
yum check-update > $TMPDIR/updates
if (( $(wc -l $TMPDIR/updates | awk '{print $1}') > 2 ))
 then
    printWarning "$(egrep -v "^Loaded|^$" $TMPDIR/updates | wc -l) updates available. These can be found in $TMPDIR/updates.  It is recommended to run yum -y update"
 else
    printOK "All Packages up to date"
 
fi
}

function checkDisks {
echo -e "
############################
  Checking Disk Partitions 
############################"
echo
df -Pkh | grep -v 'Filesystem' > $TMPDIR/df.status
while read DISK
do
        LINE=$(echo $DISK | awk '{print $1,"\tMounted at ",$6,"\tis ",$5," used","\twith",$4," free space"}')
        mount=$(echo $DISK | awk '{print $1}')
        used=$(echo $DISK | awk '{print $5}' | rev | cut -c 2- | rev)
        echo -e $LINE
        if (( $used > 85 ))
        then
	  printWarning "$mount has used more than 85% (${used}%).  Could be worth adding more storage?"
        fi

done < $TMPDIR/df.status
echo
# Check pulp partition
if (( $(df | grep -c pulp) < 1 ))
then
    printWarning "/var/lib/pulp should be mounted on a separate partition"
fi

# Check mongo partition
if (( $(df | grep -c mongo) < 1 ))
then
    printWarning "/var/lib/mongodb should be mounted on a separate partition"
fi

}

function checkFirewallRules {
echo -e "
###########################
  Checking Firewall Rules 
###########################"
a=$(systemctl is-active firewalld 2> /dev/null)
if [[ $a == "unknown" ]]
then
    echo "Not checking firewall as it isn't currently running"
    return 1
else
iptables -n -L IN_public_allow > $TMPDIR/iptables
cat << EOF >> $TMPDIR/iptables_required
tcp dpt:22
tcp dpt:443
tcp dpt:80
tcp dpt:8140
tcp dpt:9090
tcp dpt:8080
udp dpt:67
udp dpt:68
tcp dpt:53
udp dpt:69
udp dpt:53
tcp dpt:5671
tcp dpt:5674
EOF

while read line 
  do
    port=$(echo $line | awk -F":" '{print $2}')
    proto=$(echo $line | awk '{print $1}')
    if (( $(grep -c "$line" $TMPDIR/iptables) > 0 ))
      then
	printOK "$port ($proto) has been opened"
      else
	printError "$port ($proto) has been NOT been opened"
    fi
  done < $TMPDIR/iptables_required
fi
}

function checkSatelliteConfig {
echo -e "
#######################################
## Checking Satellite Configuration  ##
#######################################"

## Organisations
hammer --csv --csv-separator=" " organization list| sort -n | grep -v "Id " > $TMPDIR/orgs
if (( $(grep -c "Default_Organization" $TMPDIR/orgs) > 0 ))
then
  printWarning "The Default_Organization is still set.  Best to remove this in a production environment"
fi


## Location List
echo
hammer --csv --csv-separator=" " location list | sort -n | grep -v "Id " > $TMPDIR/locations
totalLocations=$(wc -l $TMPDIR/locations | awk '{print $1}')
echo " + $totalLocations Locations found"
while read line
do
  id=$(echo $line | awk '{print $1}')
  location=$(echo $line | awk '{print $2}')
  hammer --output csv location  info --id=${id} > $TMPDIR/location_${location}
  totalSubnets=$(tr ',' '\n' < $TMPDIR/location_${location}  | grep -c Subnets)
  echo "  + Details for location \"${location}\" are in $TMPDIR/location_${location}"
  ## Add subnets
  echo "  - $totalSubnets Subnet(s) found for ${location}"
  for subnet in $(tr ',' '\n' < $TMPDIR/location_${location}  | grep -n  Subnets | awk -F":" '{print $1}')
  do
    locationSubnet=$(tail -1 $TMPDIR/location_${location} | awk -F"," -v net=${subnet} '{print $net}')
    echo "   - $locationSubnet"
  done

done < $TMPDIR/locations

## Capsules
echo 
hammer --csv --csv-separator=" " capsule list| sort -n | grep -v "Id " > $TMPDIR/capsules
totalCapsules=$(wc -l $TMPDIR/capsules | awk '{print $1}')
echo " + $totalCapsules Capsule(s) found"
while read line
do
  id=$(echo $line | awk '{print $1}')
  name=$(echo $line | awk '{print $2}')
  fqdn=$(echo $line | awk '{print $3}' | sed -e "s/[^/]*\/\/\([^@]*@\)\?\([^:/]*\).*/\2/")
  hammer capsule info --id=${id} > $TMPDIR/capsule_${name}  
  echo " + Details for capsule \"${name}\" are in $TMPDIR/capsule_${name}"
  echo -ne " - Features: "
  awk '/Features: / {for (i=2; i<NF; i++) printf $i " "; print $NF}' $TMPDIR/capsule_${name} 
  checkDNS ${fqdn}
  echo -e " + Checking network connectivity between $(hostname) and ${fqdn}"
  ping -c 1 ${fqdn} > /dev/null
  if [[ $? -eq 0 ]]
  then
    nmap -p T:443,5647,5646,8443,9090 ${fqdn} | grep "^[0-9]" > $TMPDIR/capsule_firewall_${name}
    while read nmap_line
    do
      port=$(echo $nmap_line | awk '{print $1}')
      status=$(echo $nmap_line | awk '{print $2}')
      if [[ $status == "closed" ]]
      then
	printWarning "Port $port is closed on $fqdn"
      else
	printOK "Port $port is open to $fqdn"  
      fi
    done < $TMPDIR/capsule_firewall_${name}
  else
    printError "$fqdn is not responding to ping?"
  fi
done < $TMPDIR/capsules

## Subnets
echo
echo " + Subnets"
hammer --csv --csv-separator=" " subnet list| sort -n | grep -v "Id " > $TMPDIR/subnets
while read line
do
  id=$(echo $line | awk '{print $1}')
  name=$(echo $line | awk '{print $2}')
  hammer subnet info --id=${id} > $TMPDIR/subnet_${name}  
  echo " - Details for subnet \"${name}\" are in $TMPDIR/subnet_${name}"
done < $TMPDIR/subnets
}


#################
## MAIN SCRIPT ##
#################

checkGeneralSetup
checkDisks
checkNetworkConnection
getType
checkSubscriptions

echo -e "
#######################
  Checking OS Services 
#######################"
checkDNS $(hostname)
checkSELinux
checkOSupdates
for service in firewalld ntpd 
do
  checkService ${service}
done
checkFirewallRules
echo -e "
#######################################
  Checking Katello/Satellite Services 
#######################################"
for service in mongod qpidd qdrouterd tomcat foreman-proxy foreman-tasks pulp_celerybeat pulp_resource_manager pulp_workers httpd
do
  checkService ${service}
done

checkSatelliteConfig


####################
## Output Results ##
####################

if (( $warnings > 0 ))
then
  echo 
  echo " + Total Warnings: $warnings"
  cat $TMPDIR/warnings
else
  echo
  echo " + No warnings"
fi

if (( $errors > 0 ))
then
  echo
  echo " + Total Errors: $errors"
  cat $TMPDIR/errors
  echo
else
  echo
  echo " + No errors"
  echo
fi

if [[ -s $TMPDIR/remedialAction ]]
then
  echo " + Remedial Action:"
  cat $TMPDIR/remedialAction
fi

  
exit




