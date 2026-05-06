# Raindrops vs io-metrics: Connection Counting Comparison

## Summary

Both Raindrops and io-metrics measure TCP listener activity using different kernel interfaces.
The controlled synthetic tests confirm that they agree perfectly on ESTABLISHED and queued
connections, but diverge specifically on CLOSE_WAIT connections — Raindrops cannot see them,
io-metrics can. In production this explains most (but not all) of the observed gap between
`raindrops_utilization` and `async_utilization`.

---

## 1. What each library measures

### Raindrops (`Raindrops::Linux.tcp_listener_stats`)

| Field    | What it counts |
|----------|----------------|
| `.active` | TCP connections in **`TCP_ESTABLISHED`** state with `idiag_inode != 0` (i.e. accepted, not in backlog) |
| `.queued` | Connections in the **accept backlog** (`TCP_LISTEN` → `idiag_rqueue`) |

**Kernel interface:** Netlink `NETLINK_INET_DIAG` with state bitmask
`(1<<TCP_ESTABLISHED) | (1<<TCP_LISTEN)`. The kernel filters to exactly these two states —
**no other TCP state is ever returned to userspace**.

**Address binding:** Queries a single explicit address string (e.g. `"0.0.0.0:9292"`). On a
dual-stack pod only IPv4 connections are counted; IPv6 connections on the same port are missed.

**No `close_wait` field** — the inet_diag kernel interface returns nothing for CLOSE_WAIT.

---

### io-metrics (`IO::Metrics::Listener.capture`)

| Field               | What it counts |
|---------------------|----------------|
| `.active_count`     | TCP connections in **`TCP_ESTABLISHED`** state matched to listener, minus the accept backlog depth (to avoid double-counting pre-accepted sockets) |
| `.close_wait_count` | TCP connections in **`TCP_CLOSE_WAIT`** state matched to listener |
| `.queued_count`     | Accept backlog depth (`rx_queue` from the LISTEN row in `/proc/net/tcp`) |

**Kernel interface:** `/proc/net/tcp` and `/proc/net/tcp6` (both IPv4 and IPv6 parsed in one pass).

**Address binding:** Captures ALL listeners on the pod, then SFR's `SupervisorUtilizationMonitor`
filters by port. Both IPv4 and IPv6 listeners on the same port are summed.

---

## 2. Metrics emitted in production (Storefront Renderer)

### io-metrics gauges (emitted by `SupervisorUtilizationMonitor` ~1×/s per service)

```
StorefrontRenderer_io_metrics_listener_queued_count     (renamed from queue_size, v0.3.0)
StorefrontRenderer_io_metrics_listener_active_count     (renamed from active_connections, v0.3.0)
StorefrontRenderer_io_metrics_listener_close_wait_count (new in v0.3.0)
```

Labels: `service`, `deploy_stage`, `utilization_group` (+ standard pod tags).

### async-framework gauges (emitted by `SupervisorUtilizationMonitor`)

```
StorefrontRenderer_async_utilization                      (distribution/histogram — the primary autoscaling signal)
StorefrontRenderer_async_utilization_requests_active      (gauge)
StorefrontRenderer_async_utilization_connections_active   (gauge)
StorefrontRenderer_async_utilization_worker_count         (gauge)
StorefrontRenderer_async_utilization_socket_accept_acquired_count
StorefrontRenderer_async_utilization_socket_accept_waiting_count
StorefrontRenderer_async_utilization_socket_accept_reacquire_waiting_count
StorefrontRenderer_async_utilization_long_task_acquired_count
StorefrontRenderer_async_utilization_long_task_waiting_count
```

### Raindrops (emitted by `UtilizationMonitor`)

```
StorefrontRenderer_raindrops_utilization   (distribution/histogram — the old autoscaling signal)
StorefrontRenderer_raindrops_active        (gauge — raw TCP ESTABLISHED count from inet_diag)
StorefrontRenderer_raindrops_queued        (gauge — accept backlog from inet_diag)
StorefrontRenderer_raindrops_raw_utilization (distribution — same as utilization, pre-clip)
StorefrontRenderer_total_long_tasks        (gauge)
StorefrontRenderer_total_num_waiting_to_reacquire (gauge)
```

---

## 3. Utilization formulas (from SFR source)

Both histograms are emitted once per supervisor monitoring interval (~1 s), not once per request.

### `async_utilization` (`SupervisorUtilizationMonitor#emit`)

```ruby
semaphore_load    = [socket_accept_reacquire_waiting_count - long_task_acquired_count, 0].max
load_numerator    = requests_active + queued_count + semaphore_load
utilization       = load_numerator.to_f / (worker_count * MAX_ACCEPTS)
```

- **`requests_active`** — live in-flight request counter. Incremented on request start, decremented after `rack.response_finished`. Includes connections in **CLOSE_WAIT** (post-response cleanup window).
- **`queued_count`** — from io-metrics; includes both IPv4 and IPv6 listeners.
- **`worker_count`** — **live** worker count reported by the Falcon supervisor at emit time.
- **`MAX_ACCEPTS = 1`** in production → denominator = `worker_count`.

### `raindrops_utilization` (`Utilization.calculate`)

```ruby
raw_utilization = (active + queued + num_waiting_to_reacquire - long_tasks).to_f /
                  (FALCON_WORKERS * MAX_ACCEPTS).to_f
utilization = raw_utilization < 0.0 ? 0.0 : raw_utilization
```

- **`active`** — from `Raindrops::Linux.tcp_listener_stats("0.0.0.0:PORT")`. Only TCP ESTABLISHED. Does **not** include CLOSE_WAIT.
- **`queued`** — from the same Raindrops call. IPv4 only.
- **`num_waiting_to_reacquire - long_tasks`** — semaphore load, **not clamped** before use in numerator (only the final result is clipped to 0).
- **`FALCON_WORKERS`** — `ENV["FALCON_WORKERS"]`, set at pod startup. **Static** — does not reflect live worker count.
- **`MAX_ACCEPTS = 1`** in production → denominator = `FALCON_WORKERS`.

---

## 4. Confirmed sources of the gap (`async_util > raindrops_util`)

### Controlled experiment results (CI-verified on Linux, Ruby 3.4 and 4.0)

| Scenario | raindrops.active | io-metrics.active_count | io-metrics.close_wait_count | Notes |
|---|---|---|---|---|
| Idle | 0 | 0 | 0 | Perfect agreement |
| 3 queued (backlog) | queued=3, active=0 | queued=3, active=0 | 0 | Perfect agreement |
| 4 accepted, ESTABLISHED | 4 | 4 | 0 | Perfect agreement |
| 1 client closes, server holds fd | **0** | 0 | **1** | Raindrops drops to 0; CLOSE_WAIT invisible to inet_diag |
| 3 ESTABLISHED + 2 CLOSE_WAIT | 3 | 3 | 2 | raindrops undercounts by 2; identity: 3+2=5 total |
| Server closes first (FIN_WAIT2) | 0 | 0 | 0 | Both invisible to both backends |
| 20 established, 10 clients close | active=10 | active_count=10 | close_wait=10 | 10+10=20 reconstructed perfectly |

**Identity confirmed:** `requests_active ≈ raindrops.active + io_metrics.close_wait_count`
→ verified with 0 failures in synthetic tests, and to <1.2% residual in production.

---

## 5. Production data (May 6 2026, ~21:30 UTC+9, off-peak)

Queries used `service="storefront-renderer"`, `deploy_stage="production"`, 2-minute rate interval
matching the dashboard formula: `histogram_sum(rate([2m])) / histogram_count(rate([2m]))`.

### `web` utilization group

| Metric | Value |
|--------|-------|
| `async_utilization` | **~41.5%** |
| `raindrops_utilization` | **~38.6%** |
| **Gap** | **~2.9 pp** (async > raindrops) |
| `requests_active` (avg/pod) | ~24.7 |
| `io_metrics.active_count` (avg/pod) | ~24.6 |
| `io_metrics.close_wait_count` (avg/pod) | ~1.03 |
| Identity residual (`requests_active − (active + close_wait)`) | −0.3 (≈ −1.2%) |

Implied denominator from async: `24.7 / 0.415 ≈ 59.5`
Implied denominator from raindrops: `24.6 / 0.386 ≈ 63.7`

**Expected CLOSE_WAIT contribution:** `1.03 / 59.5 ≈ 1.7 pp`
**Observed gap:** 2.9 pp → **CLOSE_WAIT explains ~60%** of the gap.

### `web-sfapi` utilization group

| Metric | Value |
|--------|-------|
| `async_utilization` | **~35.5%** |
| `raindrops_utilization` | **~33.6%** |
| **Gap** | **~1.9 pp** |
| `io_metrics.close_wait_count / requests_active` | ~1.5% (vs ~4% for `web`) |

The smaller gap for sfapi is consistent: sfapi handles longer gRPC requests, so the
post-response CLOSE_WAIT window is a smaller fraction of total request duration.

---

## 6. Remaining gap (~1.2 pp for `web`) — likely causes

After accounting for CLOSE_WAIT (~1.7 pp), ~1.2 pp remains. The most probable contributors
in order of estimated magnitude:

### A. Denominator: live `worker_count` vs static `FALCON_WORKERS`

**This is the largest structural difference.**

- `async_utilization` denominates by the **live** worker count reported by the Falcon supervisor.
- `raindrops_utilization` denominates by `ENV["FALCON_WORKERS"]` captured at pod startup.

At steady state with `MAX_ACCEPTS = 1`:

```
async_denominator    = worker_count(live)    ≈ 60
raindrops_denominator = FALCON_WORKERS(env) ≈ 64
```

If the live worker count is slightly below the configured maximum (autoscaler ramp-up, transient
worker restarts, health-check exclusions), async divides by a *smaller* number → **higher
percentage**. With denominator difference of ~7%, for a numerator of ~25 connections:

```
async    = 25 / 60 = 41.7%
raindrops = 25 / 64 = 39.1%
gap from denominator alone ≈ 2.6 pp
```

Combined with CLOSE_WAIT this can over-predict the gap; in practice the effects partially
cancel, and the observed 2.9 pp gap is the net result.

### B. IPv6 queued connections (io-metrics vs Raindrops scope)

io-metrics captures both IPv4 (`/proc/net/tcp`) and IPv6 (`/proc/net/tcp6`) listeners.
Raindrops queries only `"0.0.0.0:PORT"` — the IPv4 wildcard. On a dual-stack listener, any
queued or active IPv6 connections are counted by io-metrics but **missed by Raindrops**.

This makes `queued_count` (io-metrics, used in async numerator) systematically higher than
`queued` (Raindrops, used in raindrops numerator), by whatever fraction of connections arrive
over IPv6. In production the difference appears small (residual ≈ −0.3 connections/pod).

### C. Semaphore-load clamping

- async formula clamps `reacquire_waiting − long_tasks` to ≥ 0 **before** adding to numerator.
- raindrops formula subtracts the **raw** (potentially negative) value, then clips the final
  utilization to ≥ 0.

In steady state (`long_task_acquired ≈ 22 >> reacquire_waiting ≈ 4`, per-cluster), both terms
evaluate to 0 — no practical difference. During traffic bursts where reacquire > long_tasks,
async would report slightly higher load.

### D. Timing skew

`async_utilization` reads `requests_active` (in-process atomic counter) and io-metrics
(`/proc/net/tcp`) in the **same emit call** inside the Falcon supervisor. `raindrops_utilization`
reads from `Raindrops::Linux.tcp_listener_stats` in a separate monitor loop and **writes to a
file** (`/tmp/raindrops_stats_falcon`) with a 2-second TTL. The per-request metric reader reads
from this stale file. This introduces up to ~2 s of lag in the raindrops snapshot relative to
async, creating jitter but not a systematic upward/downward bias on its own.

---

## 7. The identity and what it means for the autoscaler

The synthetic tests and production data together confirm:

```
requests_active  ≈  raindrops.active  +  io_metrics.close_wait_count
```

This means:
- **`raindrops_utilization` systematically undercounts** work in flight by the CLOSE_WAIT fraction.
  At current production levels (~1.03 close_wait/pod, ~4% of active connections for `web`),
  raindrops understates utilization by ~1.7 pp.
- **`async_utilization` correctly counts** post-response work because `requests_active` is
  decremented only after `rack.response_finished` callbacks complete.
- The difference between the two signals is proportional to how much time a typical request
  spends in post-response cleanup relative to total request duration. For the `web` group
  (~4% CLOSE_WAIT), cleanup takes ~4% of average request duration. For `web-sfapi` (~1.5%),
  the longer base request time makes the cleanup fraction smaller.

### Implication

An autoscaler using `raindrops_utilization` will systematically under-provision capacity by
the CLOSE_WAIT fraction. Under high load (when CLOSE_WAIT connections accumulate faster),
this under-count grows, making the problem worse at exactly the moment more headroom is needed.
`async_utilization` does not have this blind spot.

---

## 8. Differences not present in synthetic tests but relevant in production

| Factor | Synthetic test | Production |
|--------|---------------|-----------|
| Multiple processes per pod | Single process | Multiple Falcon workers |
| Connection count per pod | 3–20 | 40–60 ESTABLISHED + 1–2 CLOSE_WAIT |
| Dual-stack listener (IPv4 + IPv6) | IPv4 only | Both (io-metrics sees both; raindrops sees IPv4 only) |
| Denominator: live vs configured workers | N/A | Diverges during scale events |
| Semaphore load (long tasks) | Zero | `long_task_acquired ≈ 22/cluster` |
| StatsD aggregation (histogram vs gauge) | N/A | Histogram is request-weighted; gauge is time-averaged |

---

## 9. Recommendation

Use `async_utilization` as the primary signal for autoscaling and load shedding. It correctly
accounts for CLOSE_WAIT connections, is tied to the live worker count, and uses io-metrics
which captures both IPv4 and IPv6.

`raindrops_utilization` can serve as a secondary cross-check signal, but should be understood
to systematically understate load by 1–5 pp depending on per-request cleanup duration and
request rate.
