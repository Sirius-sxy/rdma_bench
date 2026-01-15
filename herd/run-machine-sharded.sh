#!/bin/bash
# Client startup script for HERD multi-server with sharding
# Usage: ./run-machine-sharded.sh <machine_id> [num_servers] [num_shards] [replication_factor]

# A function to echo in blue color
function blue() {
	es=`tput setaf 4`
	ee=`tput sgr0`
	echo "${es}$1${ee}"
}

export HRD_REGISTRY_IP="10.113.1.47"
export MLX5_SINGLE_THREADED=1
export MLX4_SINGLE_THREADED=1

if [ "$#" -lt 1 ]; then
    blue "Usage: ./run-machine-sharded.sh <machine_id> [num_servers] [num_shards] [replication_factor]"
    blue "  machine_id: ID of this client machine"
    blue "  num_servers: Total number of servers (default: 4)"
    blue "  num_shards: Total number of shards (default: 4)"
    blue "  replication_factor: Number of replicas per shard (default: 3)"
    blue ""
    blue "Example:"
    blue "  On client machine 0: ./run-machine-sharded.sh 0 4 4 3"
    blue "  On client machine 1: ./run-machine-sharded.sh 1 4 4 3"
    exit 1
fi

MACHINE_ID=$1
NUM_SERVERS=${2:-4}
NUM_SHARDS=${3:-4}
REPLICATION=${4:-3}

blue "Starting HERD client with sharding configuration:"
blue "  Machine ID: $MACHINE_ID"
blue "  Num Servers: $NUM_SERVERS"
blue "  Num Shards: $NUM_SHARDS"
blue "  Replication Factor: $REPLICATION"

blue "Removing hugepages"
shm-rm.sh 1>/dev/null 2>/dev/null

num_threads=14		# Threads per client machine

blue "Running $num_threads client threads"

sudo LD_LIBRARY_PATH=/usr/local/lib/ -E \
	numactl --cpunodebind=0 --membind=0 ./main \
	--num-threads $num_threads \
	--base-port-index 0 \
	--num-server-ports 2 \
	--num-client-ports 2 \
	--is-client 1 \
	--update-percentage 0 \
	--machine-id $MACHINE_ID \
	--num-servers $NUM_SERVERS \
	--num-shards $NUM_SHARDS \
	--replication-factor $REPLICATION &

blue "Client machine $MACHINE_ID started successfully"
