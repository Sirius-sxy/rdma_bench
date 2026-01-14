#!/bin/bash
# Startup script for HERD multi-server with sharding and replication
# Usage: ./run-servers-sharded.sh <server_id> [num_servers] [num_shards] [replication_factor]

# A function to echo in blue color
function blue() {
	es=`tput setaf 4`
	ee=`tput sgr0`
	echo "${es}$1${ee}"
}

export HRD_REGISTRY_IP="10.113.1.47"
export MLX5_SINGLE_THREADED=1
export MLX4_SINGLE_THREADED=1

# Parse arguments
if [ "$#" -lt 1 ]; then
    blue "Usage: ./run-servers-sharded.sh <server_id> [num_servers] [num_shards] [replication_factor]"
    blue "  server_id: ID of this server (0-based)"
    blue "  num_servers: Total number of servers (default: 4)"
    blue "  num_shards: Total number of shards (default: 4)"
    blue "  replication_factor: Number of replicas per shard (default: 3)"
    blue ""
    blue "Example for 4 servers with 3 replicas:"
    blue "  On server 0: ./run-servers-sharded.sh 0 4 4 3"
    blue "  On server 1: ./run-servers-sharded.sh 1 4 4 3"
    blue "  On server 2: ./run-servers-sharded.sh 2 4 4 3"
    blue "  On server 3: ./run-servers-sharded.sh 3 4 4 3"
    exit 1
fi

SERVER_ID=$1
NUM_SERVERS=${2:-4}
NUM_SHARDS=${3:-4}
REPLICATION=${4:-3}

blue "Starting HERD server with sharding configuration:"
blue "  Server ID: $SERVER_ID / $NUM_SERVERS"
blue "  Total Shards: $NUM_SHARDS"
blue "  Replication Factor: $REPLICATION"

blue "Removing SHM key 24 (request region hugepages)"
sudo ipcrm -M 24 2>/dev/null

blue "Removing SHM keys used by MICA"
for i in `seq 0 28`; do
	key=`expr 3185 + $i`
	sudo ipcrm -M $key 2>/dev/null
	key=`expr 4185 + $i`
	sudo ipcrm -M $key 2>/dev/null
done

# Only reset memcached on server 0 to avoid conflicts
if [ "$SERVER_ID" -eq 0 ]; then
    blue "Reset server QP registry (server 0 only)"
    sudo pkill memcached
    memcached -l 0.0.0.0 1>/dev/null 2>/dev/null &
    sleep 2
else
    blue "Waiting for memcached registry (started by server 0)"
    sleep 3
fi

blue "Starting master process for server $SERVER_ID"
sudo LD_LIBRARY_PATH=/usr/local/lib/ -E \
	numactl --cpunodebind=0 --membind=0 ./main \
	--master 1 \
	--base-port-index 0 \
	--num-server-ports 2 \
	--num-servers $NUM_SERVERS \
	--num-shards $NUM_SHARDS \
	--replication-factor $REPLICATION \
	--server-id $SERVER_ID &

# Give the master process time to create and register per-port request regions
sleep 2

blue "Starting worker threads for server $SERVER_ID"
sudo LD_LIBRARY_PATH=/usr/local/lib/ -E \
	numactl --cpunodebind=0 --membind=0 ./main \
	--is-client 0 \
	--base-port-index 0 \
	--num-server-ports 2 \
	--postlist 32 \
	--num-servers $NUM_SERVERS \
	--num-shards $NUM_SHARDS \
	--replication-factor $REPLICATION \
	--server-id $SERVER_ID &

blue "Server $SERVER_ID started successfully"
