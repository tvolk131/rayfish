# Reliability (packet-loss) e2e test

Four droplets form an **open**-network full mesh; the test probes every
pair in both directions for packet loss over the rayfish tunnel, with the raw
public-IP link as the baseline.

```bash
tests/e2e.sh reliability             # provision (if needed) + deploy + probe + assert
tests/e2e.sh reliability provision   # spin up the 4 instances -> .servers
tests/e2e.sh reliability teardown    # destroy them
```

## What it proves

rayfish ships traffic as iroh QUIC **datagrams**, which are not retransmitted, so
under congestion, MTU mismatch, relay fallback, or reader backpressure the tunnel
can silently drop packets. This test exists to surface exactly that: if a clean
link between two cloud servers loses packets *through rayfish* but not directly,
the protocol needs work.

Per pair, per direction, over both the `rayfish` TUN IP and the `direct` public
IP:

- **ICMP burst** — `ping -c 1000 -i 0.01` (100 packets/s)
- **ICMP flood** — `ping -f -c 10000` (as fast as the link accepts)
- **iperf3 UDP** — `iperf3 -u -b 50M -t 10`, reading `lost_percent`

One additional WebSocket test sends repeated small replies and messages up to
1 MiB from srv-b to srv-a. Every frame is checked; a 10-second stall fails.

A probe **FAILs** when the rayfish-path loss exceeds the direct-path loss by more
than `MARGIN` percentage points (default `0.5`), so genuine internet drops on
the underlying link aren't blamed on rayfish. Both paths must return a valid
percentage: missing or malformed results fail as measurement errors, rather
than being treated as zero loss. Direct loss is always reported. A per-run
markdown table is saved under `results/`.

## First-run findings (4× DEV1-S in fr-par-1, the fleet this suite ran on then)

- **ICMP burst and flood: 0% loss over the rayfish tunnel on every directed pair**
  (12/12), matching the direct baseline. The datagram data path holds up under
  sustained ICMP load between cloud servers.
- **No UDP measurement was collected in that run.** The direct path measured
  fine, but the TUN path yielded no `lost_percent`, so that run provides no UDP
  packet-loss conclusion. Linux creates its TUN with a 1280-byte MTU; the mesh
  accepts IP packets up to 1500 bytes and fragments them when a QUIC path's
  datagram budget is smaller. Those are separate limits, and neither alone
  establishes why iperf3 returned no measurement. Reproduce and inspect the
  iperf3, firewall and transport errors before attributing it to packet loss.

## Environment overrides

| Var | Default | Meaning |
|-----|---------|---------|
| `RATE` | `50M` | iperf3 UDP target bitrate |
| `DURATION` | `10` | iperf3 seconds per run |
| `PING_COUNT` | `1000` | ICMP burst packets (at `-i 0.01`) |
| `FLOOD_COUNT` | `10000` | ICMP flood packets |
| `MARGIN` | `0.5` | rayfish loss may exceed direct by this many pp before failing |

Plus the shared `REGION`/`SIZE`/`IMAGE`/`SSH_KEY`/`KEEP_STATE` overrides (see
[`../README.md`](../README.md)).
