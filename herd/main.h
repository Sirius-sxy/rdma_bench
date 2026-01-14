#include <stdint.h>

/*
 * The polling logic in HERD requires the following:
 * 1. 0 < MICA_OP_GET < MICA_OP_PUT < HERD_OP_GET < HERD_OP_PUT
 * 2. HERD_OP_GET = MICA_OP_GET + HERD_MICA_OFFSET
 * 3. HERD_OP_PUT = MICA_OP_PUT + HERD_MICA_OFFSET
 *
 * This allows us to detect HERD requests by checking if the request region
 * opcode is more than MICA_OP_PUT. And then we can convert a HERD opcode to
 * a MICA opcode by subtracting HERD_MICA_OFFSET from it.
 */
#define HERD_MICA_OFFSET 10
#define HERD_OP_GET (MICA_OP_GET + HERD_MICA_OFFSET)
#define HERD_OP_PUT (MICA_OP_PUT + HERD_MICA_OFFSET)

#define HERD_NUM_BKTS (2 * 1024 * 1024)
#define HERD_LOG_CAP (1024 * 1024 * 1024)

#define HERD_NUM_KEYS (8 * 1024 * 1024)
#define HERD_VALUE_SIZE 32

/* Request sizes */
#define HERD_GET_REQ_SIZE (16 + 1) /* 16 byte key + opcode */

/* Key, op, len, val */
#define HERD_PUT_REQ_SIZE (16 + 1 + 1 + HERD_VALUE_SIZE)

/* Configuration options */
#define MAX_SERVER_PORTS 4
#define NUM_WORKERS 12
#define NUM_CLIENTS 70

/* Sharding and replication configuration */
#define HERD_MAX_SERVERS 16      /* Maximum number of servers in the cluster */
#define HERD_DEFAULT_NUM_SERVERS 4
#define HERD_DEFAULT_NUM_SHARDS 4
#define HERD_DEFAULT_REPLICATION 3

/* Performance options */
#define WINDOW_SIZE 32 /* Outstanding requests kept by each client */
#define NUM_UD_QPS 1   /* Number of UD QPs per port */
#define USE_POSTLIST 1

#define UNSIG_BATCH 64 /* XXX Check if increasing this helps */
#define UNSIG_BATCH_ (UNSIG_BATCH - 1)

/* SHM key for the 1st request region created by master. ++ for other RRs.*/
#define MASTER_SHM_KEY 24
#define RR_SIZE (16 * 1024 * 1024) /* Request region size */
#define OFFSET(wn, cn, ws) \
  ((wn * NUM_CLIENTS * WINDOW_SIZE) + (cn * WINDOW_SIZE) + ws)

struct thread_params {
  int id;
  int base_port_index;
  int num_server_ports;
  int num_client_ports;
  int update_percentage;
  int postlist;

  /* Sharding and replication parameters */
  int num_servers;       /* Total number of servers in the cluster */
  int num_shards;        /* Total number of shards */
  int replication_factor; /* Number of replicas per shard */
  int server_id;         /* ID of this server (0 to num_servers-1) */
};

void* run_master(void* arg);
void* run_worker(void* arg);
void* run_client(void* arg);

/* Sharding and replication helper functions */
static inline int herd_get_shard_for_key(uint32_t key_bkt, int num_shards) {
  return key_bkt % num_shards;
}

static inline int herd_get_primary_server_for_shard(int shard_id, int num_servers) {
  return shard_id % num_servers;
}

static inline void herd_get_servers_for_shard(int shard_id, int num_servers,
                                               int replication_factor, int* servers) {
  for (int i = 0; i < replication_factor; i++) {
    servers[i] = (shard_id + i) % num_servers;
  }
}

static inline int herd_server_owns_shard(int server_id, int shard_id,
                                          int num_servers, int replication_factor) {
  for (int i = 0; i < replication_factor; i++) {
    if (((shard_id + i) % num_servers) == server_id) {
      return 1;
    }
  }
  return 0;
}

static inline int herd_key_belongs_to_server(uint32_t key_bkt, int server_id,
                                               int num_servers, int num_shards,
                                               int replication_factor) {
  int shard_id = herd_get_shard_for_key(key_bkt, num_shards);
  return herd_server_owns_shard(server_id, shard_id, num_servers, replication_factor);
}
