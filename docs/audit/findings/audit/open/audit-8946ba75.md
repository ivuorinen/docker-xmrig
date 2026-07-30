---
id: audit-8946ba75
auditor: audit
severity: low
category: reliability
area: deployment.yaml
status: open
found: 2026-07-30
---

# No signal distinguishes a mining pod from a pod that is Ready at zero hashrate

## Problem

Residual gap left open deliberately after fixing `audit-bdf51ba5`. The liveness and
readiness probes prove the process is responsive, not that it is mining.

## Evidence

Measured against the fixed image. A container whose pool is unreachable:

```
$ docker inspect --format '{{.State.Health.Status}}' k8ssim
healthy
$ docker exec k8ssim wget -qO- http://127.0.0.1:8080/2/summary | jq -c '{connected:.connection.uptime, pool:.connection.pool, hashrate:.hashrate.total}'
{"connected":0,"pool":"","hashrate":[0.0,0.0,0.0]}
```

The healthcheck passes and the readiness probe would mark the pod Ready, while
`connection.pool` is empty and hashrate is zero. xmrig logs `DNS error` every five
seconds and never exits.

## Impact

A pod that has lost its pool — bad DNS, pool outage, wrong credentials, a typo in
the configMap — reports healthy indefinitely and produces nothing. Nothing in the
repository surfaces it.

## Fix

Deliberately *not* fixed in the probe: making liveness depend on `connection.pool`
turns a pool-side outage into a restart loop, which is worse than the symptom, and
the connected case could not be verified in this environment.

The correct place is external alerting. Scrape the API and alert on the condition:

```bash
wget -qO- http://<pod>:8080/2/summary \
  | jq -e '.connection.pool != "" and (.hashrate.total[0] // 0) > 0'
```

For Prometheus, xmrig does not export a metrics endpoint; use a small exporter or
a blackbox check over the same JSON. Whoever runs this must opt into a threshold
appropriate to their pool's reliability — which is why it is not hardcoded here.
