# HERD Multi-Server Sharding and Replication

This document describes the multi-server sharding and replication feature added to HERD.

## Overview

The original HERD implementation runs on a single server with multiple worker threads. This extension adds support for:

1. **Multiple servers**: Distribute the KV store across multiple physical servers
2. **Sharding**: Partition the key space into multiple shards
3. **Replication**: Each shard is replicated across multiple servers for fault tolerance and load balancing

## Architecture

### Sharding Strategy

- The total key space is divided into `num_shards` shards
- Each key belongs to one shard based on: `shard_id = key.bkt % num_shards`
- Keys are generated using CityHash128, ensuring uniform distribution

### Replication Strategy (Ring-based)

For a given shard `i`, the replica servers are determined using a ring topology:
- Replica servers: `(i + j) % num_servers` where `j = 0` to `replication_factor - 1`

**Example:** 4 servers, 4 shards, replication factor = 3

```
Shard 0 → Servers: 0 (primary), 1, 2
Shard 1 → Servers: 1 (primary), 2, 3
Shard 2 → Servers: 2 (primary), 3, 0
Shard 3 → Servers: 3 (primary), 0, 1
```

Each server stores approximately `(num_shards * replication_factor) / num_servers` shards.

## Configuration Parameters

### Command Line Arguments

All processes (master, workers, clients) accept the following new parameters:

- `--num-servers <N>`: Total number of servers in the cluster (default: 4)
- `--num-shards <N>`: Total number of shards (default: 4)
- `--replication-factor <N>`: Number of replicas per shard (default: 3)
- `--server-id <ID>`: ID of this server, 0-based (default: 0)

### Default Values

Defined in `main.h`:
```c
#define HERD_DEFAULT_NUM_SERVERS 4
#define HERD_DEFAULT_NUM_SHARDS 4
#define HERD_DEFAULT_REPLICATION 3
```

## Usage

### Starting Servers

Use the `run-servers-sharded.sh` script on each server:

```bash
# On server 0
./run-servers-sharded.sh 0 4 4 3

# On server 1
./run-servers-sharded.sh 1 4 4 3

# On server 2
./run-servers-sharded.sh 2 4 4 3

# On server 3
./run-servers-sharded.sh 3 4 4 3
```

**Script Arguments:**
1. `server_id`: ID of this server (required)
2. `num_servers`: Total servers (optional, default: 4)
3. `num_shards`: Total shards (optional, default: 4)
4. `replication_factor`: Replicas per shard (optional, default: 3)

### Starting Clients

Use the `run-machine-sharded.sh` script on each client machine:

```bash
# On client machine 0
./run-machine-sharded.sh 0 4 4 3

# On client machine 1
./run-machine-sharded.sh 1 4 4 3
```

**Script Arguments:**
1. `machine_id`: ID of this client machine (required)
2. `num_servers`: Total servers (optional, default: 4)
3. `num_shards`: Total shards (optional, default: 4)
4. `replication_factor`: Replicas per shard (optional, default: 3)

### Manual Invocation

You can also manually invoke the binary with full control:

**Master:**
```bash
sudo ./main \
    --master 1 \
    --base-port-index 0 \
    --num-server-ports 2 \
    --num-servers 4 \
    --num-shards 4 \
    --replication-factor 3 \
    --server-id 0
```

**Worker:**
```bash
sudo ./main \
    --is-client 0 \
    --base-port-index 0 \
    --num-server-ports 2 \
    --postlist 32 \
    --num-servers 4 \
    --num-shards 4 \
    --replication-factor 3 \
    --server-id 0
```

**Client:**
```bash
sudo ./main \
    --num-threads 14 \
    --base-port-index 0 \
    --num-server-ports 2 \
    --num-client-ports 2 \
    --is-client 1 \
    --update-percentage 0 \
    --machine-id 0 \
    --num-servers 4 \
    --num-shards 4 \
    --replication-factor 3
```

## Implementation Details

### Server-Side (worker.c)

1. **Shard-aware initialization**: Workers only populate keys belonging to their server's shards
2. **Memory efficiency**: Each server only stores `~(total_keys * replication_factor / num_servers)` keys
3. **Verification**: Workers can validate incoming requests belong to their shards (optional)

### Client-Side (client.c)

1. **Shard awareness**: Clients know the sharding configuration
2. **Request routing**: Currently, clients connect to specific servers (simplified model)
3. **Key distribution**: Clients generate keys uniformly across all shards

### Helper Functions (main.h)

```c
// Get shard ID for a key
int herd_get_shard_for_key(uint32_t key_bkt, int num_shards);

// Get primary server for a shard
int herd_get_primary_server_for_shard(int shard_id, int num_servers);

// Get all replica servers for a shard
void herd_get_servers_for_shard(int shard_id, int num_servers,
                                 int replication_factor, int* servers);

// Check if server owns a shard
int herd_server_owns_shard(int server_id, int shard_id,
                            int num_servers, int replication_factor);

// Check if key belongs to a server
int herd_key_belongs_to_server(uint32_t key_bkt, int server_id,
                                 int num_servers, int num_shards,
                                 int replication_factor);
```

## Example Configurations

### Configuration 1: 4 Servers, High Replication
```bash
# 4 servers, 4 shards, 3 replicas (75% redundancy)
./run-servers-sharded.sh <id> 4 4 3
```

Each shard is stored on 3 out of 4 servers. Can tolerate 1 server failure per shard.

### Configuration 2: 8 Servers, Many Shards
```bash
# 8 servers, 16 shards, 3 replicas
./run-servers-sharded.sh <id> 8 16 3
```

More fine-grained sharding, better load distribution.

### Configuration 3: 4 Servers, Lower Replication
```bash
# 4 servers, 8 shards, 2 replicas (50% redundancy)
./run-servers-sharded.sh <id> 4 8 2
```

Less storage overhead, but reduced fault tolerance.

## Performance Considerations

1. **Storage per server**: Approximately `(num_shards * replication_factor / num_servers) * keys_per_shard`
2. **Network traffic**: Clients need to route requests to correct servers
3. **Load balancing**: Read requests can be served by any replica
4. **Consistency**: Current implementation assumes strong consistency (writes to primary)

## Limitations and Future Work

1. **Client-Server Mapping**: Current implementation uses simplified client-server connections. Full implementation would require:
   - Clients connecting to all servers
   - Dynamic request routing based on key hashes
   - Load balancing across replicas

2. **Failure Handling**: Not implemented in this version

3. **Dynamic Reconfiguration**: Shard/replica configuration is static

4. **Write Replication**: Currently writes go to one replica; full replication requires:
   - Write-all or quorum-based writes
   - Consistency protocols (e.g., Paxos, Raft)

## Testing

To verify the sharding is working correctly:

1. Check worker logs for shard ownership:
   ```
   Worker 0 (server 0): Populated MICA instance with 3 shards
   ```

2. Verify key distribution:
   - Each server should have `num_shards * replication / num_servers` shards
   - Total keys per server should be approximately `HERD_NUM_KEYS * replication / num_servers`

3. Check performance:
   - Throughput should scale with number of servers
   - Client-side routing should distribute load evenly

## Troubleshooting

**Problem**: Server fails to start with "assertion failed"
- **Solution**: Check that `server_id < num_servers` and `replication_factor <= num_servers`

**Problem**: Clients cannot connect
- **Solution**: Ensure memcached registry is running and `HRD_REGISTRY_IP` is set correctly

**Problem**: Uneven load distribution
- **Solution**: Verify that `num_shards` is a multiple of `num_servers` for balanced distribution

## References

- Original HERD paper: [HERD: A Case for High-Efficiency RDMA Design](https://www.cs.cmu.edu/~akalia/doc/sigcomm14/herd_draft.pdf)
- MICA paper: [MICA: A Holistic Approach to Fast In-Memory Key-Value Storage](https://www.cs.cmu.edu/~fawnproj/papers/mica-nsdi2014.pdf)
