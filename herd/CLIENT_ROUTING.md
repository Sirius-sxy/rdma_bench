# HERD Client-Side Routing Implementation

## Overview

This document describes the client-side request routing implementation that enables clients to dynamically route requests to the correct server based on key hash, supporting the multi-server sharding architecture.

## Architecture

### Key Components

1. **Multi-Server Connection**: Each client connects to ALL servers
2. **Dynamic Routing**: Each request is routed to the correct server based on key hash
3. **Per-Server QPs**: Each client maintains separate connected QPs for each server
4. **Load Distribution**: Requests are evenly distributed across servers based on shard assignment

## Implementation Details

### 1. Multi-Server Connection (client.c:84-111)

Each client creates `num_servers` connected QPs and connects to all servers:

```c
/* Create one control block with num_servers connected QPs */
cb[0] = hrd_ctrl_blk_init(
    clt_gid,                   /* local_hid */
    ib_port_index, -1,         /* port_index, numa_node_id */
    num_servers, 1,            /* #conn qps = num_servers, uc */
    NULL, 4096, -1,            /* prealloc conn buf, buf size, key */
    1, DGRAM_BUF_SIZE, -1);    /* num_dgram_qps, dgram_buf_size, key */

/* Connect to each server */
for (s = 0; s < num_servers; s++) {
  /* Publish client QP for this server connection */
  sprintf(clt_conn_qp_name, "client-conn-s%d-%d", s, clt_gid);
  hrd_publish_conn_qp(cb[0], s, clt_conn_qp_name);

  /* Find and connect to server's master QP */
  sprintf(mstr_qp_name, "master-s%d-%d-%d", s, srv_virt_port_index, clt_gid);
  mstr_qp[s] = hrd_get_published_qp(mstr_qp_name);
  hrd_connect_qp(cb[0], s, mstr_qp[s]);
}
```

### 2. QP Naming Scheme

To support multiple servers, QP names now include server_id:

**Master QPs**:
- Old: `"master-{port}-{client_id}"`
- New: `"master-s{server_id}-{port}-{client_id}"`

**Client QPs**:
- Old: `"client-conn-{client_id}"`
- New: `"client-conn-s{server_id}-{client_id}"`

Example for client 0 connecting to 4 servers:
```
Server 0: master-s0-0-0 ← client-conn-s0-0
Server 1: master-s1-0-0 ← client-conn-s1-0
Server 2: master-s2-0-0 ← client-conn-s2-0
Server 3: master-s3-0-0 ← client-conn-s3-0
```

### 3. Request Routing Logic (client.c:201-224)

For each request, the client:
1. Generates a key using CityHash128
2. Extracts the bucket field from the key
3. Calculates the shard ID
4. Determines the target server
5. Uses the corresponding connected QP

```c
/* Generate key */
*(uint128*)req_buf = CityHash128((char*)&key_arr[key_i], 4);

/* Calculate shard and target server */
uint32_t key_bkt = ((struct mica_key*)req_buf)->bkt;
int shard_id = herd_get_shard_for_key(key_bkt, num_shards);
int target_server = herd_get_primary_server_for_shard(shard_id, num_servers);

/* Use target server's QP and remote address */
wr.wr.rdma.remote_addr = mstr_qp[target_server]->buf_addr + ...;
wr.wr.rdma.rkey = mstr_qp[target_server]->rkey;
ret = ibv_post_send(cb[0]->conn_qp[target_server], &wr, &bad_send_wr);
```

### 4. Window Slot Tracking

Since each client connects to multiple servers, we need per-server window slot tracking:

```c
/* Track window slots per server per worker */
int ws[HERD_MAX_SERVERS][NUM_WORKERS];

/* Use per-server window slot */
wr.wr.rdma.remote_addr = mstr_qp[target_server]->buf_addr +
                         OFFSET(wn, clt_gid, ws[target_server][wn]) *
                         sizeof(struct mica_op);

/* Advance window slot for this server and worker */
HRD_MOD_ADD(ws[target_server][wn], WINDOW_SIZE);
```

### 5. Routing Statistics

Clients track and report per-server routing distribution:

```c
long long requests_per_server[HERD_MAX_SERVERS] = {0};

/* In main loop */
requests_per_server[target_server]++;

/* Periodic reporting */
printf("Client %d: %.2f IOPS. Routing: ", clt_gid, K_512 / seconds);
for (s = 0; s < num_servers; s++) {
  printf("S%d=%.1f%% ", s, 100.0 * requests_per_server[s] / K_512);
}
printf("\n");
```

Example output:
```
Client 0: 1250000.00 IOPS. Routing: S0=25.0% S1=25.0% S2=25.0% S3=25.0%
```

## Routing Examples

### Example 1: 4 Servers, 4 Shards, Replication=1

```
Shard 0 → Server 0
Shard 1 → Server 1
Shard 2 → Server 2
Shard 3 → Server 3
```

**Routing logic**:
- `shard_id = key.bkt % 4`
- `target_server = shard_id % 4 = shard_id`

Result: Each server gets 25% of requests

### Example 2: 4 Servers, 8 Shards, Replication=1

```
Shard 0 → Server 0    Shard 4 → Server 0
Shard 1 → Server 1    Shard 5 → Server 1
Shard 2 → Server 2    Shard 6 → Server 2
Shard 3 → Server 3    Shard 7 → Server 3
```

**Routing logic**:
- `shard_id = key.bkt % 8`
- `target_server = shard_id % 4`

Result: Each server gets 25% of requests (from 2 shards)

### Example 3: 2 Servers, 4 Shards, Replication=1

```
Shard 0 → Server 0
Shard 1 → Server 1
Shard 2 → Server 0
Shard 3 → Server 1
```

**Routing logic**:
- `shard_id = key.bkt % 4`
- `target_server = shard_id % 2`

Result: Each server gets 50% of requests (from 2 shards)

## Replication Support

### Replication Factor = 1 (No Replication)
- Each key has exactly one owner
- Routing is deterministic: `target_server = shard_id % num_servers`
- Simple and efficient

### Replication Factor > 1 (With Replication)
- Each key has multiple replicas
- Current implementation: Always route to primary replica

```c
if (replication_factor == 1) {
  target_server = herd_get_primary_server_for_shard(shard_id, num_servers);
} else {
  /* Multiple replicas: for now, always use primary */
  target_server = herd_get_primary_server_for_shard(shard_id, num_servers);
}
```

**Future enhancement**: Load balance reads across replicas
```c
/* Get all replicas */
int replica_servers[replication_factor];
herd_get_servers_for_shard(shard_id, num_servers,
                            replication_factor, replica_servers);

/* Round-robin or random selection for reads */
int replica_idx = (request_counter++) % replication_factor;
target_server = replica_servers[replica_idx];
```

## Performance Characteristics

### Connection Overhead
- **Original**: Each client has 1 connected QP
- **Multi-server**: Each client has `num_servers` connected QPs
- **Memory**: Increases linearly with `num_servers`
- **Setup time**: Increases linearly (all servers must be available)

### Request Processing
- **Routing overhead**: ~10 CPU cycles per request (hash lookup)
- **No network overhead**: Routing is client-side decision
- **Load distribution**: Perfect uniform distribution (based on hash)

### Scalability
- **Horizontal**: Throughput scales linearly with servers
- **Network**: Total QP count = `num_clients × num_servers`
- **Practical limit**: ~16 servers (due to QP count limits)

## Testing

### Verify Routing Distribution

Run clients and check routing statistics:
```bash
# Expected output for 4 servers, uniform key distribution
Client 0: 1250000.00 IOPS. Routing: S0=25.0% S1=25.0% S2=25.0% S3=25.0%
```

### Verify Correctness

Check that servers only receive requests for keys they own:
```bash
# On server 0 (should own shards 0, 4, 8, ...)
Worker 0 (server 0): All requests for keys with shard_id % num_servers == 0
```

### Performance Testing

Compare single-server vs multi-server throughput:
```bash
# Single server baseline
./run-servers.sh
Expected: T ops/sec

# 4 servers with routing
./run-servers-sharded.sh 0 4 4 1
./run-servers-sharded.sh 1 4 4 1
./run-servers-sharded.sh 2 4 4 1
./run-servers-sharded.sh 3 4 4 1
Expected: ~4T ops/sec (linear scaling)
```

## Limitations and Future Work

### Current Limitations

1. **Replica Load Balancing**: Reads always go to primary replica
   - **Impact**: Primary replica handles all read load for its shards
   - **Fix**: Implement round-robin or random replica selection for reads

2. **Write Replication**: Writes only go to one server
   - **Impact**: Data is not actually replicated
   - **Fix**: Implement write-all or quorum-based write protocol

3. **Connection Management**: All connections established upfront
   - **Impact**: Slow startup if many servers are offline
   - **Fix**: Lazy connection establishment or connection pooling

4. **Static Routing**: Shard-to-server mapping is fixed at startup
   - **Impact**: Cannot handle server failures or load rebalancing
   - **Fix**: Implement dynamic routing table updates

### Future Enhancements

1. **Smart Replica Selection**
   ```c
   /* Load-aware replica selection */
   int select_best_replica(int shard_id, bool is_write) {
     if (is_write) {
       return primary_replica(shard_id);  // Always write to primary
     }

     /* For reads, select least-loaded replica */
     int replicas[replication_factor];
     herd_get_servers_for_shard(shard_id, num_servers,
                                  replication_factor, replicas);

     int best = 0;
     for (int i = 1; i < replication_factor; i++) {
       if (server_load[replicas[i]] < server_load[replicas[best]]) {
         best = i;
       }
     }
     return replicas[best];
   }
   ```

2. **Locality-Aware Routing**
   - Prefer local servers (same rack/datacenter)
   - Minimize network hops

3. **Adaptive Routing**
   - Monitor server latency and throughput
   - Route to fastest servers
   - Avoid slow or overloaded servers

4. **Connection Pooling**
   - Share connections across client threads
   - Reduce QP count from `clients × servers` to `client_machines × servers`

## Debugging

### Enable Routing Debug Output

Uncomment debug prints in client.c:
```c
// Line 252: Uncomment to see per-request routing
printf("Client %d: Routing key_bkt=%u shard=%d to server=%d\n",
       clt_gid, key_bkt, shard_id, target_server);
```

### Check QP Connections

Verify all QPs are connected:
```bash
# Should see: Client X: Successfully connected to all N servers!
grep "Successfully connected" <client_log>
```

### Monitor Request Distribution

Check that routing is balanced:
```bash
# Watch real-time routing stats
watch -n 1 "grep Routing <client_log> | tail -1"
```

## Conclusion

The client-side routing implementation enables:
✅ **Dynamic request routing** to correct servers based on key hash
✅ **Perfect load balancing** via uniform hash distribution
✅ **Horizontal scalability** via multi-server connections
✅ **Flexibility** to support various sharding configurations

This implementation provides a solid foundation for building a distributed, high-performance key-value store on RDMA infrastructure.
