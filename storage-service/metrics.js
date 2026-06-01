// Prometheus instrumentation for the storage-service.
//
// Exposes a Registry plus a small set of operational metrics targeting
// the parts of the service most likely to fail or get slow:
//   - Steam login and GC connection state (the two long-lived
//     connections every API call depends on).
//   - Cumulative connect / disconnect events so reconnect storms show
//     up in a graph.
//   - HTTP request volume and latency (broken down by route).
//   - Casket-fetch outcomes and durations — caskets are the slowest
//     thing the service does, and the Steam GC routinely takes
//     30 seconds for a large one.
//
// Default Node.js process metrics (CPU, memory, event-loop lag,
// uptime) come from prom-client's `collectDefaultMetrics`.

const client = require('prom-client');

const register = new client.Registry();
register.setDefaultLabels({ service: 'cs2-storage' });
client.collectDefaultMetrics({ register });

// ── Steam / GC state ──────────────────────────────────────

const steamLoggedIn = new client.Gauge({
  name: 'cs2_storage_steam_logged_in',
  help: '1 if logged in to Steam, 0 otherwise',
  registers: [register],
});

const gcConnected = new client.Gauge({
  name: 'cs2_storage_gc_connected',
  help: '1 if connected to the CS2 Game Coordinator, 0 otherwise',
  registers: [register],
});

const gcConnectionsTotal = new client.Counter({
  name: 'cs2_storage_gc_connections_total',
  help: 'Cumulative count of successful GC connection events',
  registers: [register],
});

const gcDisconnectionsTotal = new client.Counter({
  name: 'cs2_storage_gc_disconnections_total',
  help: 'Cumulative count of GC disconnection events, labelled by reason',
  labelNames: ['reason'],
  registers: [register],
});

// ── HTTP traffic ──────────────────────────────────────────

const httpRequestsTotal = new client.Counter({
  name: 'cs2_storage_http_requests_total',
  help: 'Total HTTP requests, labelled by route pattern, method, and status',
  labelNames: ['route', 'method', 'status'],
  registers: [register],
});

const httpRequestDurationSeconds = new client.Histogram({
  name: 'cs2_storage_http_request_duration_seconds',
  help: 'HTTP request latency in seconds, by route pattern and method',
  labelNames: ['route', 'method'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5, 10, 30, 60],
  registers: [register],
});

// ── Casket-fetch hot path ─────────────────────────────────

const casketFetchesTotal = new client.Counter({
  name: 'cs2_storage_casket_fetches_total',
  help: 'Cumulative count of casket-fetch operations, labelled by outcome',
  labelNames: ['result'], // success | error | timeout
  registers: [register],
});

const casketFetchDurationSeconds = new client.Histogram({
  name: 'cs2_storage_casket_fetch_duration_seconds',
  help: 'Time spent reading a casket from the GC, in seconds',
  buckets: [1, 5, 10, 20, 30, 45, 60, 90],
  registers: [register],
});

module.exports = {
  register,
  steamLoggedIn,
  gcConnected,
  gcConnectionsTotal,
  gcDisconnectionsTotal,
  httpRequestsTotal,
  httpRequestDurationSeconds,
  casketFetchesTotal,
  casketFetchDurationSeconds,
};
