#!/bin/bash
cd "$(dirname "$0")"
if [[ ${BASH_VERSION%%[^0-9.]*} < 4 ]]; then
echo "This script requires bash version 4 or greater";
exit 1
fi
command -v /usr/sbin/arp >/dev/null 2>&1 || { echo >&2 "I require /usr/sbin/arp but it's not installed.  Aborting."; exit 1; }

# We should find a way to automatically update this
SWITCH_LIST="128.237.157.253 128.237.157.254"
OUTPUT=$1

source libsnmphelper.sh
source libarphelper.sh
source libjsonhelper.sh

# create some Associative Arrays
declare -A switch_mapping_mac
declare -A switch_mapping_ip
declare -A switch_mapping_port
declare -A switch_internal_mac
declare -A switch_internal_ports

eval "$(arp_mac_to_ip)"
eval "$(arp_mac_to_dns)"


echo "Will now query $SWITCH_LIST for connected macs, ports, and bridges information"
for switch in $SWITCH_LIST; do
	echo "Querying $switch"
	eval "$(snmp_switch_get_mac_to_bridge_port "$switch")"
	switch_mapping_ip[$switch]="root"
	for mac in "${!rtn[@]}"; do
		port=${rtn[$mac]}
		switch_mapping_mac[$switch,$mac]=$port
		switch_mapping_port[$switch,$port]+=" $mac"
		switch_internal_ports[$switch]+=" $port"
	done
done


echo "Resolving switch hierarchy"
for ip in "${!switch_mapping_ip[@]}"; do
	
	switch_internal_ports[$ip]=$(for i in ${switch_internal_ports[$ip]}; do echo $i;done | sort -u)
	switch_internal_ports[$ip]=${switch_internal_ports[$ip]//$'\n'/ }

	switch_mac_address=$(snmp_switch_mac_address $ip)
	switch_internal_mac[$ip,self]=$switch_mac_address
	echo "My address: $ip"

	for other_switch_ip in "${!switch_mapping_ip[@]}"; do
		if [ "$other_switch_ip" == "$ip" ]; then continue; fi
		echo "Testing whether I am a child of $other_switch_ip"
		port=${switch_mapping_mac[$other_switch_ip,$switch_mac_address]}
		if [ $port ]; then
			echo "Detected I am child connected to $other_switch_ip:$port"
			switch_mapping_ip[$ip]=$other_switch_ip
			switch_mapping_port[$other_switch_ip,$port,child]=$ip
		else 
		echo "Testing if $other_switch_ip is my child"	
		eval "$(snmp_switch_mac_port_mapping $ip)"
		for my_port_mac in "${!rtn[@]}"; do
			port=${switch_mapping_mac[$other_switch_ip,$my_port_mac]}
			if [ $port ]; then
				echo "Detected that $other_switch_ip:$port is child of me"
				switch_mapping_port[$other_switch_ip,$port,parent]=$ip
			fi
		done
		fi
	done
done
#find the parent switch
parent_switch=
for ip in "${!switch_mapping_ip[@]}"; do
	if [[ "${switch_mapping_ip[$ip]}" == "root" ]]; then
		parent_switch=$ip;
		break;
	fi
done

# Explicity setup some outputs for generate_connections_list
node_list=""
link_list=""
echo "Computing JSON output"
generate_connections_list $parent_switch


# Save stdout to file discriptor 3
exec 3>&1
if [ -n "$OUTPUT" ]; then
	#change stdout to be conntected to the input file
    exec 3>$OUTPUT
fi
exec 4>&1
exec 1>&3
echo '{"nodes":['
echo "${node_list%?}"
echo '],"links":['
echo "${link_list%?}"
echo "]}"

# Restore stdout and close temporary file description
exec 1>&4 4>&-
exec 3>&-