#!/bin/bash

help()
{
    #TODO: Add help text here
    echo "This script installs Datastax Opscenter and configures nodes"
    echo "Parameters:"
    echo "-u username used to connect to and configure data nodes"
    echo "-p password used to connect to and configure data nodes"
    echo "-d dse nodes to manage (suuccessive ip range 10.0.0.4-8 for 8 nodes)"
    echo "-e use ephemeral storage (yes/no)"
}

# Log method to control/redirect log output
log()
{
    # If you want to enable this logging add a un-comment the line below and add your account id
    #curl -X POST -H "content-type:text/plain" --data-binary "${HOSTNAME} - $1" https://logs-01.loggly.com/inputs/<key>/tag/es-extension,${HOSTNAME}
    echo "$1"
}

log "Begin execution of cassandra script extension on ${HOSTNAME}"

# You must be root to run this script
if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

# TEMP FIX - Re-evaluate and remove when possible
# This is an interim fix for hostname resolution in current VM (If it does not exist add it)
grep -q "${HOSTNAME}" /etc/hosts
if [ $? -eq $SUCCESS ]
then
  echo "${HOSTNAME}found in /etc/hosts"
else
  echo "${HOSTNAME} not found in /etc/hosts"
  # Append it to the hsots file if not there
  echo "127.0.0.1 ${HOSTNAME}" >> /etc/hosts
  log "hostname ${HOSTNAME} added to /etchosts"
fi

#Script Parameters
CLUSTER_NAME="Test Cluster"
EPHEMERAL=0
DSE_ENDPOINTS=""
ADMIN_USER=""
SSH_KEY_PATH=""

#Loop through options passed
while getopts :n:d:u:p:e optname; do
    log "Option $optname set with value ${OPTARG}"
  case $optname in
    n)
      CLUSTER_NAME=${OPTARG}
      ;;
  	u) #Credentials used for node install
      ADMIN_USER=${OPTARG}
      ;;
    p) #Credentials used for node install
      ADMIN_PASSWORD=${OPTARG}
      ;;
    d) #Static dicovery endpoints
      DSE_ENDPOINTS=${OPTARG}
      ;;
    e) #place data on local resource disk
      EPHEMERAL=1
      ;;
    h)  #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
      help
      exit 2
      ;;
  esac
done

#Install Java
add-apt-repository -y ppa:webupd8team/java
apt-get -y update 
echo debconf shared/accepted-oracle-license-v1-1 select true | sudo debconf-set-selections
echo debconf shared/accepted-oracle-license-v1-1 seen true | sudo debconf-set-selections
apt-get -y install oracle-java7-installer
 
 #Tune environment
cat >> /etc/security/limits.d/cassandra.conf <<EOF
* - memlock unlimited
* - nofile 100000
* - nproc 32768
* - as unlimited
EOF
 
echo "vm.max_map_count = 131072" >> /etc/sysctl.conf
sudo sysctl -p

#Install opscenter
echo "deb http://debian.datastax.com/community stable main" | sudo tee -a /etc/apt/sources.list.d/datastax.community.list
curl -L http://debian.datastax.com/debian/repo_key | sudo apt-key add -
apt-get update
apt-get install opscenter

# Start Ops Center
sudo service opscenterd start

# CONFIGURE NODES

# Expand a list of successive ip range and filter my local local ip from the list
# This increments the last octet of an IP start range using a defined value
# 10.0.0.4-3 would be converted to "10.0.0.4 10.0.0.5 10.0.0.6"
expand_ip_range() {
    IFS='-' read -a IP_RANGE <<< "$1"
    BASE_IP=`echo ${IP_RANGE[0]} | cut -d"." -f1-3`
    LAST_OCTET=`echo ${IP_RANGE[0]} | cut -d"." -f4-4`

    #Get the IP Addresses on this machine
    declare -a MY_IPS=`ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'`
    declare -a EXPAND_STATICIP_RANGE_RESULTS=()

    for (( n=LAST_OCTET; n<("${IP_RANGE[1]}"+LAST_OCTET) ; n++))
    do
        HOST="${BASE_IP}.${n}"
        if ! [[ "${MY_IPS[@]}" =~ "${HOST}" ]]; then
            EXPAND_STATICIP_RANGE_RESULTS+=($HOST)
        fi
    done
    echo "${EXPAND_STATICIP_RANGE_RESULTS[@]}"
}

# Convert the DSE endpoint range to a list for the provisioniing configuration
NODE_IP_LIST=$(expand_ip_range "$DSE_ENDPOINTS")

get_node_fingerprints() {
    TR=($1)

    ACCEPTED_FINGERPRINTS=""
    for HOST in "${TR[@]}";
    do
        ssh-keyscan -p 22 -t rsa "$HOST" > /tmp/tmpsshkeyhost.pub
        HOSTKEY=$(ssh-keygen -lf /tmp/tmpsshkeyhost.pub)

        # TODO - This is a bit of a formatting hack job, need to clean it up
        HOSTKEY=`echo ${HOSTKEY} | cut -d" " -f1-2`
        HOSTKEY+=" (RSA)"
        ACCEPTED_FINGERPRINTS+="\"$HOST\": \"$HOSTKEY\","
    done
    ACCEPTED_FINGERPRINTS="${ACCEPTED_FINGERPRINTS%?}"

    echo "$ACCEPTED_FINGERPRINTS"
}

NODE_CONFIG_LIST="\"${NODE_IP_LIST// /\",\"}\""
ACCEPTED_FINGERPRINTS=$(get_node_fingerprints "$NODE_IP_LIST")

# Create node provisioning document
sudo tee provision.json > /dev/null <<EOF
{
    "cassandra_config": {
        "authenticator": "org.apache.cassandra.auth.AllowAllAuthenticator",
        "auto_snapshot": true,
        "start_native_transport": true,
        "cluster_name": "${CLUSTER_NAME}",
        "column_index_size_in_kb": 64,
        "commitlog_directory": "/mnt/resource/cassandra/commitlog",
        "commitlog_sync": "periodic",
        "commitlog_sync_period_in_ms": 10000,
        "compaction_throughput_mb_per_sec": 16,
        "concurrent_reads": 32,
        "concurrent_writes": 32,
        "data_file_directories": [
            "/mnt/resource/cassandra/data"
        ],
        "dynamic_snitch_badness_threshold": 0.1,
        "dynamic_snitch_reset_interval_in_ms": 600000,
        "dynamic_snitch_update_interval_in_ms": 100,
        "encryption_options": {
            "internode_encryption": "none",
            "keystore": "conf/.keystore",
            "keystore_password": "cassandra",
            "truststore": "conf/.truststore",
            "truststore_password": "cassandra"
        },
        "endpoint_snitch": "SimpleSnitch",
        "hinted_handoff_enabled": true,
        "incremental_backups": false,
        "index_interval": 128,
        "initial_token": null,
        "key_cache_save_period": 14400,
        "key_cache_size_in_mb": null,
        "max_hint_window_in_ms": 3600000,
        "partitioner": "org.apache.cassandra.dht.RandomPartitioner",
        "request_scheduler": "org.apache.cassandra.scheduler.NoScheduler",
        "row_cache_save_period": 0,
        "row_cache_size_in_mb": 0,
        "rpc_keepalive": true,
        "rpc_port": 9160,
        "rpc_server_type": "sync",
        "saved_caches_directory": "/mnt/resource/cassandra/saved_caches",
        "snapshot_before_compaction": false,
        "ssl_storage_port": 7001,
        "storage_port": 7000,
        "thrift_framed_transport_size_in_mb": 15,
        "thrift_max_message_length_in_mb": 16,
        "trickle_fsync": false,
        "trickle_fsync_interval_in_kb": 10240
    },
    "install_params": {
        "username": "${ADMIN_USER}",
        "password": "${ADMIN_PASSWORD}",
        "package": "dsc",
        "version": "2.1.1"
    },
    "nodes": [
        ${NODE_CONFIG_LIST}
    ],
    "accepted_fingerprints": {
        ${ACCEPTED_FINGERPRINTS}
    }
}
EOF

# "10.0.0.11": "2048 ee:58:a1:31:a8:b6:b2:d0:8c:0d:57:fa:3c:b3:64:9e (RSA)",
#      "10.0.0.10": "2048 5a:f1:08:60:bc:c4:ab:0e:a4:5e:23:c6:c2:f3:10:dc (RSA)",
#      "10.0.0.12": "2048 dd:ef:a4:a5:a4:41:e2:fd:ed:cf:8c:12:5f:56:fa:77 (RSA)"

# We seem to be trying to hit the endpoint too early the service is not listening yet
sleep 14

curl -X POST localhost:8888/provision -d @provision.json
# {"message": "Hosts need SSH key fingerprint verification", "fingerprints": {"10.0.0.11": "2048 ee:58:a1:31:a8:b6:b2:d0:8c:0d:57:fa:3c:b3:64:9e (RSA)", "10.0.0.10": "2048 5a:f1:08:60:bc:c4:ab:0e:a4:5e:23:c6:c2:f3:10:dc (RSA)", "10.0.0.12": "2048 dd:ef:a4:a5:a4:41:e2:fd:ed:cf:8c:12:5f:56:fa:77 (RSA)"}}
