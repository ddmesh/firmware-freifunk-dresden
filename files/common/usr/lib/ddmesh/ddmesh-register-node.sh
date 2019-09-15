#!/bin/sh

LOGGER_TAG="register.node"
AUTO_REBOOT=1

#check if initial setup was run before
if [ ! -f /etc/config/ddmesh ]; then logger -t $LOGGER_TAG "ddmesh not ready - ignore register.node" ; exit; fi

node="$(uci get ddmesh.system.node)"
key="$(uci get ddmesh.system.register_key)"
eval $(/usr/lib/ddmesh/ddmesh-ipcalc.sh -n $node)

CERT="--ca-certificate=/etc/ssl/certs/register.crt"

echo "usage: register_node.sh [new_node]"
echo "current node: [$node]"
echo "current key: [$key]"

#check if user want's to register with a different node
test -n "$1" && node=$1

test -z "$node" && {
	echo "node number not set or passed as parameter"
	exit 1
}

test -z "$key" && {
	echo "no register key"
	exit 1
}

echo "Try to register node [$node], key [$key]"
n="$(uclient-fetch $CERT -O- $(uci get credentials.registration.register_service_url)$key\&node=$node 2>/dev/null)"

if [ -z "$n" ]; then
	echo "connection error"
	exit 1
fi

json=$(echo "$n" | sed -n '/^{/{:L;p;n;bL;}')

eval $(echo "$json" | jsonfilter \
	-e j_version='@.version' \
	-e j_status='@.registration.status' \
	-e j_error='@.registration.error' \
	-e j_node='@.registration.node' \
	-e j_netid='@.control.netid' \
	-e j_gateway='@.control.trigger.gateway' \
	-e j_dns='@.control.trigger.dns' \
	-e j_reboot='@.control.trigger.reboot' \
	-e j_geoloc='@.control.trigger.geoloc' \
)

#echo "j_version:$j_version"
#echo "j_status:$j_status"
#echo "j_error:$j_error"
#echo "j_node:$j_node"
#echo "j_gateway:$j_gateway"
#echo "j_netid:$j_netid"
#echo "j_dns:$j_dns"
#echo "j_reboot:$j_reboot"
#echo "j_geoloc:$j_geoloc"

case "$j_status" in
	ok)
			rebooting=0

			node=$j_node
			logger -s -t $LOGGER_TAG "SUCCESS: node=[$node]; key=[$key] registered."

			if [ "$j_reboot" = "1" ]; then
				rebooting=1
			fi

			if [ "$j_geoloc" = "1" ]; then
				/usr/lib/ddmesh/ddmesh-geoloc.sh update-config 
			fi

			#update dns 
			dns="$(uci -q get ddmesh.network.internal_dns)"
			if [ -n "$j_dns" -a "$j_dns" != "$dns" ]; then
				uci set ddmesh.network.internal_dns="$j_dns"
				logger -s -t $LOGGER_TAG "update dns to $j_dns."
				uci_commit=1
				rebooting=1
			fi

			#update netid if >0
			netid="$(uci -q get ddmesh.network.mesh_network_id)"
			if [ -n "$j_netid" -a "$j_netid" != "0" -a "$j_netid" != "$netid" ]; then
				uci set ddmesh.network.mesh_network_id="$j_netid"
				logger -s -t $LOGGER_TAG "update netid to $j_netid."
				uci_commit=1
				rebooting=1
			fi

			#update preferred gateway
			gw="$(uci -q get ddmesh.bmxd.preferred_gateway)"
			if [ -n "$j_gateway" -a "$j_gateway" != "$gw" ]; then
				if [ "$j_gateway" = "0.0.0.0" ]; then
					uci -q delete ddmesh.bmxd.preferred_gateway
					bmxd -cp -
				else
					uci set ddmesh.bmxd.preferred_gateway=$j_gateway
					bmxd -cp $j_gateway
				fi
				uci_commit=1

				logger -s -t $LOGGER_TAG "update preferred gateway to $j_gateway."
			fi

			test "$uci_commit" = 1 && uci_commit.sh

			#if node wasn't stored before
			[ -n "$node" ] && [ "$(uci get ddmesh.system.node)" != "$node" ] && {

				echo "commit node [$node]"
				uci set ddmesh.system.node=$node
				#config depending on node must be updated and causes a second reboot
				uci set ddmesh.boot.boot_step=2
			  	uci_commit.sh

				echo "update https certificate"
				rm /etc/uhttpd.key
				rm /etc/uhttpd.crt

				rebooting=1
			}

			echo "updated (reboot:$rebooting)."

			test "$rebooting" = 1 && sleep 5 && echo "rebooting..." && reboot

		;;
	error) 		logger -s -t $LOGGER_TAG "$j_error"
		;;
	*)	 	logger -s -t $LOGGER_TAG "ERROR: invalid response"
		;;
esac

#echo "$n"

