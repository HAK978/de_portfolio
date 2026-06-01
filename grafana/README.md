# Grafana dashboard for the storage-service

`cs2-storage-dashboard.json` is the observability-as-code companion to
the Prometheus metrics exposed by `storage-service/`. It renders an
8-panel view of the backend's health, traffic, and casket-fetch
performance.

## Panels

| # | Panel                                  | What it shows                                                              |
|---|----------------------------------------|----------------------------------------------------------------------------|
| 1 | Steam login                            | Whether the VM's Steam session is up (gauge: 1 = green, 0 = red)           |
| 2 | GC connection                          | Whether the CS2 Game Coordinator is currently connected                    |
| 3 | GC disconnects (1h)                    | How many times the GC dropped in the last hour (counter increase)          |
| 4 | HTTP error rate (5m)                   | % of HTTP responses returning 5xx over the last 5 minutes                  |
| 5 | Steam login & GC connection over time  | Step-line plot of both gauges — see GC pulses during app use               |
| 6 | HTTP request rate by route             | Stacked request rate broken down by route pattern                          |
| 7 | HTTP request latency p95 by route      | p95 latency per route, computed from the duration histogram                |
| 8 | Casket fetches: rate & p95 duration    | Success/error rate plus p95 fetch latency (dual-axis)                      |

## Importing

Grafana Cloud → **Dashboards** → **New** → **Import** → upload this
file (or paste its contents). The import dialog will prompt you to map
`DS_PROMETHEUS` to your Grafana Cloud Prometheus data source — pick the
auto-provisioned one (`grafanacloud-…-prom`).

The dashboard has UID `cs2-storage-health` so re-imports update the
same dashboard in place rather than creating duplicates.

## Data source

This dashboard expects metrics scraped by Grafana Alloy from the
storage-service's `/metrics` endpoint. The Alloy config that does the
scraping is the `prometheus.scrape "cs2_storage_service"` block in
`/etc/alloy/config.alloy` on the VM:

```
prometheus.scrape "cs2_storage_service" {
  targets = [{
    __address__ = "localhost:3456",
    instance    = constants.hostname,
    job         = "cs2-storage-service",
  }]
  forward_to      = [prometheus.remote_write.metrics_service.receiver]
  scrape_interval = "30s"
  metrics_path    = "/metrics"
}
```
