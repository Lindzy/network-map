#!/bin/bash

if [[ ${BASH_VERSION%%[^0-9.]*} < 4 ]]; then
echo "This script requires bash version 4 or greater";
exit 1
fi
command -v /usr/sbin/arp >/dev/null 2>&1 || { echo >&2 "I require /usr/sbin/arp but it's not installed.  Aborting."; exit 1; }

source libsnmphelper.sh
source libarphelper.sh
declare -A switch_mapping_mac
declare -A switch_mapping_ip
declare -A switch_mapping_port
declare -A switch_internal_mac
declare -A switch_internal_ports

SWITCH_LIST="128.237.157.253 128.237.157.254"
for switch in $SWITCH_LIST; do
	echo "Fetching Switch $switch connected macs, ports, and bridges information"
	eval "$(snmp_switch_get_mac_to_bridge_port "$switch")"
	switch_mapping_ip[$switch]="root"
	for mac in "${!rtn[@]}"; do
		port=${rtn[$mac]}
		switch_mapping_mac[$switch,$mac]=$port
		switch_mapping_port[$switch,$port]+=" $mac"
		switch_internal_ports[$switch]+=" $port"
	done
done
eval "$(arp_mac_to_ip)"
eval "$(arp_mac_to_dns)"
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
node_count=-1
group=0
#find the parent switch
parent_switch=
#later we can modify this to allow non tree structure
for ip in "${!switch_mapping_ip[@]}"; do
	if [[ "${switch_mapping_ip[$ip]}" == "root" ]]; then
		parent_switch=$ip;
		break;
	fi
done
print_connection_switch(){
	local self_ip=$1
	local self_mac=${switch_internal_mac[$self_ip,self]}
	((group++))
	switch_group=$group
	if [ ! $3 ]; then
		output_node "$switch_group" "$2" "$self_mac" "Switch"
	else 
		#this is a nasty hack to find the other end of the switch port and print it
		for port in ${switch_internal_ports[$self_ip]}; do
			if [ ${switch_mapping_port[$self_ip,$port,parent]} ]; then
				output_node "$switch_group" "$2" "$self_mac" "$3:Switch:$port"
				break;
			fi
		done
	fi
	switch_node_id=$node_count
	for port in ${switch_internal_ports[$self_ip]}; do
		child_switch_ip=${switch_mapping_port[$self_ip,$port,child]}
		parent_switch_ip=${switch_mapping_port[$self_ip,$port,parent]}
		if [ $child_switch_ip ]; then
			print_connection_switch $child_switch_ip $switch_node_id "$port"
		elif [ $parent_switch_ip ]; then
			:
		else
			local nodes=${switch_mapping_port[$self_ip,$port]}
			#find a way not to convert to array?
			nodes=( $nodes )
			if [ ${#nodes[@]} == 1 ]; then
				output_node "$switch_group" "$switch_node_id" "$nodes" "$port:"
			else
				((group++))
				output_node "$group" "$switch_node_id" "" "$port"
				portid=$node_count
				for leaf in "${nodes[@]}"; do
					output_node "$group" "$portid" "$leaf" ""
				done
			fi
		fi
	done
}
node_list=""
link_list=""
output_node() {
	((node_count++))
	node_list+="{\"name\":\"${4:+$4 }${3:+${mac_to_dns["$3"]:-${mac_to_ip[$3]:-$3}}}\",\"group\":$1},"
	if [ $2 ]; then
	output_links "$2" "$node_count" ;
	fi
}
output_links() {
	link_list+="{\"source\":$1,\"target\":$2,\"value\":1},"
}
echo "Computing JSON output"
print_connection_switch $parent_switch

echo "----"
echo '{"nodes":['
echo "${node_list%?}"
echo '],"links":['
echo "${link_list%?}"
echo "]}"