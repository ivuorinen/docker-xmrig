# My xmrig Miner

This is a simple miner that uses the xmrig miner to mine Monero.

The shipped `config.json` contains a **placeholder pool address** and will not
connect until you replace it with your own pool or p2pool node.

## What is XMRig?

[XMRig](https://xmrig.com/miner) is a high performance, open source, cross platform
RandomX, KawPow, CryptoNight and AstroBWT unified CPU/GPU miner
and RandomX benchmark. Official binaries are available for
Windows, Linux, macOS and FreeBSD.

## Image layout

The manifests below depend on these paths. If you override the container's
command, match them:

| Path | What |
| --- | --- |
| `/bin/xmrig` | the miner binary |
| `/etc/xmrig/config.json` | the config the default `CMD` reads |
| `/log` | writable directory, owned by uid `10001`; unused unless you opt into file logging |
| `:8080` | xmrig HTTP API, read-only, used by the healthcheck and probes |

The container runs as uid `10001`, not root.

**The API on `:8080` has no access token.** It must bind `0.0.0.0` for the
Kubernetes probes to reach it, and `"restricted": true` keeps it read-only — but
anyone who can reach the port reads the host CPU model, its total and free
memory, the container hostname, and, once connected, the pool `user`. Do not
route it off the node.

`deployment.yaml` ships a `NetworkPolicy` that denies pod ingress — **but
NetworkPolicy is enforced by your CNI plugin, not by Kubernetes.** On a cluster
running plain Flannel or kindnet the object is accepted, appears in `kubectl get
networkpolicy`, and is silently ignored. Confirm it actually applies before
relying on it:

```bash
kubectl run np-probe --rm -it --restart=Never --image=busybox -n xmrig -- \
  wget -qO- -T 5 http://<pod-ip>:8080/2/summary && echo "NOT ENFORCED"
```

Under Compose the port is not published, so keep the miner off any network you
share with untrusted containers.

## How to use this image

**Step 1:** Clone the GitHub repo:

```bash
git clone https://github.com/ivuorinen/docker-xmrig.git
```

**Step 2:** Edit the `config.json` file after cloning it.

- Provide your pool configuration:
  - url: your-p2pool-node:3333 (replace the `CHANGE-ME.example` placeholder)
  - user: your-miner-identifier. Defaults to `${HOSTNAME}`, which xmrig expands
    to the container hostname and sends to the pool **in cleartext** — set an
    explicit value if you do not want that, or set `"tls": true` **inside the
    pool object** if your pool offers a TLS port. Note this is not the top-level
    `tls` block in `config.json`: that one configures TLS for xmrig's own HTTP
    API and does nothing for the pool connection.
  - pass: ""

Two other things travel to the pool in the same cleartext login, whatever you set
`user` to:

- `agent` — e.g. `XMRig/6.22.2 (Linux x86_64) libuv/1.52.1 gcc/15.2.0`. That
  version triple identifies this image specifically, so setting an explicit
  `user` does not make the deployment unrecognisable. Override it with the
  `user-agent` key in `config.json` (shipped as `null`, meaning "use the
  default") if that matters to you.
- `algo` — the full list of algorithms this build supports.

For all the available options,
visit [XMRig Config File](https://xmrig.com/docs/miner/config) documentation.

**Step 3:** Deploy the image as a standalone Docker container or
to a Kubernetes cluster.

### Docker

Set a limit. Without one xmrig takes every core on the host, indefinitely —
raise it deliberately:

```bash
docker run -dit --rm \
    --cpuset-cpus 0 --memory 3g \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    --volume "$(pwd)"/config.json:/etc/xmrig/config.json:ro \
    --name xmrig ivuorinen/docker-xmrig:latest
```

Why those specific flags:

- **`--cpuset-cpus`, not `--cpus`.** `--cpus` sets a CFS quota, and xmrig cannot
  see a quota — it reads the host topology through hwloc and would still start
  one mining thread per host core, then cram them all into that quota. hwloc
  *does* honour the affinity mask, so a CPU set is what actually bounds the
  thread count. Widen to `0-3` to mine on more cores.
- **`--memory 3g`, not `2g`.** RandomX fast mode allocates a fixed **2336 MiB**
  (2080 MiB dataset + 256 MiB cache) sized from host RAM, not from the limit. Two
  gigabytes is 288 MiB short: the container does not fail cleanly, it thrashes
  swap at roughly 1/4500 of its hashrate while still reporting healthy. See
  [Performance tuning](#performance-tuning).
- **`--read-only --cap-drop ALL --security-opt no-new-privileges`** match what
  `deployment.yaml` applies. Safe as configured: `config.json` is mounted `:ro`
  and `"autosave"` is `false`, so nothing needs a writable root filesystem.

The image's own `CMD` starts the miner; there is no need to pass a command.

If you prefer **Docker Compose**, edit the [`docker-compose.yml`][docker-compose.yml]
manifest as needed and run:

```bash
docker compose up -d
```

The Compose file applies the same ceiling and the same hardening.

### Kubernetes

**Step 1:** Create the `xmrig` _namespace_. Both the configmap below and
`deployment.yaml` target it by name, so this step is required:

```bash
kubectl create ns xmrig
```

**Step 2:** Create a _configmap_ in the new namespace `xmrig`
from the [`config.json`][config.json] file:

```bash
kubectl create configmap xmrig-config --from-file config.json -n xmrig
```

_remember to edit this file with your own pool configuration first — the shipped
placeholder address does not resolve and the pod will never connect_

**Step 3:** Edit the [`deployment.yaml`][deployment.yaml] file. Things you may
want to modify include:

- `image`: pin to a released tag from the [Tags][tags] tab of the Docker Hub
  repo rather than running `:latest`.
- `replicas`: number of desired pods to be running. One pod is scheduled per
  node (see `affinity`), so this is capped by your node count.
- `resources`: RandomX fast mode needs
  `requests.memory == limits.memory >= 3Gi`. They must be **equal**: a smaller
  request lets the scheduler place the pod on a node that cannot satisfy the
  2336 MiB the miner then allocates, and the pod is OOM-killed after it has
  already been admitted. See [Performance tuning](#performance-tuning) before
  changing `memory`.
- `affinity`: the manifest schedules only one pod per node. If that is not what
  you want, remove the `affinity` block.

**Step 4:** Once you are satisfied with the above manifest, create a _deployment_:

```bash
kubectl apply -f deployment.yaml
```

## Performance tuning

**Memory is the one setting you cannot get wrong.** RandomX fast mode — what the
shipped `"mode": "auto"` selects — allocates a fixed **2336 MiB** (2080 MiB
dataset + 256 MiB cache). It sizes that from the *host's* RAM, not from your
container limit, so it allocates the same amount whatever you set:

| Container memory | What happens |
| --- | --- |
| **≥ 3 GiB** (shipped default) | Normal operation. |
| 2 GiB, swap available | Thrashes. Measured at ~1/4500 hashrate, still reports healthy. |
| 2 GiB, no swap (Kubernetes) | OOM-killed during dataset init, exit 137. CrashLoopBackOff. |

If 2 GiB is a hard constraint, set `"mode": "light"` in the `randomx` block
instead. Light mode uses only the 256 MiB cache and fits comfortably, at roughly
a tenth of the hashrate — a fine trade, but make it deliberately.

The remaining options need privileges a container does not get by default. They
are worth enabling only if you can grant what they need:

| Option | Requires |
| --- | --- |
| `randomx.rdmsr` / `wrmsr` / `cache_qos` | x86 host, `msr` kernel module, `SYS_RAWIO`, `/dev/cpu`. See note 1. |
| `randomx.1gb-pages` | Host booted with `hugepagesz=1G`, plus a hugepage allocation. |
| `cpu.huge-pages` (on by default) | Host hugepages plus `IPC_LOCK`. See note 2. |
| `opencl` / `cuda` | Not available — this is a CPU-only build. See note 3. |

1. `--cap-add SYS_RAWIO --device /dev/cpu` under Docker. No effect on arm64.
2. **Docker:** host `vm.nr_hugepages` plus `--cap-add IPC_LOCK`.
   **Kubernetes:** a node with pre-allocated hugepages, a
   `resources.limits.hugepages-2Mi` entry, *and* `IPC_LOCK` added back to the
   otherwise-dropped capability set. The shipped `deployment.yaml` does none of
   these, so hugepages are off there — worth roughly 20-30% of RandomX hashrate.
   Check for `huge pages 0%` in the `randomx allocated` log line to confirm.
3. Built with `-DWITH_OPENCL=OFF -DWITH_CUDA=OFF`; adding those blocks to
   `config.json` is silently ignored. Rebuild from source for GPU mining.

With enough memory, everything above degrades to a lower hashrate rather than
failing. Memory is the exception — see the table at the top of this section.

## Logging

This Docker image sends the container logs to the `stdout`. To view the logs:

```bash
# started with `docker run --name xmrig`
docker logs xmrig

# started with `docker compose up` — Compose names the container
# <project>-xmrig-1, so address it by service name instead
docker compose logs -f xmrig
```

For Kubernetes run:

```bash
kubectl logs --follow -n xmrig <pod-name>
```

`config.json` sets `"colors": false` and `"title": false` on purpose: xmrig emits
ANSI escapes whenever colours are on, whether or not stdout is a terminal, and in
a container it never is. Leaving them on puts escape sequences between the
timestamp and every field, which breaks anchored `grep` patterns and roughly
doubles the stored size of each line in a log aggregator.

## Alerting

The liveness and readiness probes prove the process is responsive, not that it is
mining. A pod that has lost its pool — bad DNS, a pool outage, wrong credentials,
a typo in the configMap — answers the API happily at zero hashrate and stays
`Ready` indefinitely.

That is deliberate: wiring pool state into liveness would turn someone else's
outage into a restart loop. Detect it externally instead:

```bash
wget -qO- http://<pod>:8080/2/summary \
  | jq -e '.connection.pool != "" and (.hashrate.total[0] // 0) > 0'
```

**On Kubernetes that scrape is blocked by default.** The `NetworkPolicy` in
`deployment.yaml` denies *all* pod ingress. Kubelet probes are unaffected —
they originate on the node — but a monitoring client running in another pod is
not, so the check above will time out no matter how the miner is doing. Grant
your collector an explicit exception, rather than dropping the policy:

```yaml
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8080
```

Scrape from outside the cluster only if you have read the API exposure note
above and accepted it — the endpoint has no access token.

xmrig exports no Prometheus endpoint, so use a small exporter or a blackbox check
over that same JSON. Pick a threshold that suits your pool's reliability — which
is why one is not hardcoded here.

### Persistent logging

The shipped `config.json` logs to stdout only. That is deliberate — but "stdout
is rotated for you" is only true where something is actually configured to
rotate it:

| Path | Rotation |
| --- | --- |
| Compose | Capped at 3 x 10 MB — `docker-compose.yml` sets `max-size`/`max-file`. |
| `docker run` | **None by default.** The `json-file` driver grows without bound unless you pass `--log-opt max-size=10m --log-opt max-file=3` or set them in `daemon.json`. |
| Kubernetes | Depends on the kubelet's `containerLogMaxSize`/`containerLogMaxFiles` (commonly 10Mi x 5, but not guaranteed). |

To keep a file copy on the host instead, add the `log-file` key back and
bind-mount the directory it points at:

```jsonc
  "log-file": "/log/xmrig.log",
```

```bash
mkdir -p "$(pwd)"/log
sudo chown 10001 "$(pwd)"/log   # required — see below
```

The Compose and Kubernetes `/log` mounts are already wired:
[`docker-compose.yml`][docker-compose.yml] bind-mounts `./log`, and
`deployment.yaml` mounts a 512 MiB `emptyDir` (replace it with a
[Persistent Volume](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
to survive rescheduling).

The standalone `docker run` recipe above mounts only `config.json`, so add the
volume there yourself — without it xmrig writes the log inside the container's
own filesystem, where it is lost on `--rm` and invisible on the host:

```bash
    --volume "$(pwd)"/log:/log:rw \
```

Two things to know before you opt in:

- **The `chown` is not optional.** The container is uid `10001`; `./log` arrives
  from `git clone` owned by you. If xmrig cannot open the log file it writes no
  file, prints no error, and exits non-zero never — the feature is simply absent
  and nothing tells you.
- **xmrig does not rotate `xmrig.log`.** It grows until the filesystem fills.
  Rotate it on the host (`logrotate`). On Kubernetes the `emptyDir` `sizeLimit`
  makes the kubelet evict this pod rather than fill the node; raise it alongside
  `resources.limits.ephemeral-storage`, not on its own.

## Disclaimer

Use at your own discretion. This repository is by no means financial advice to
mine cryptocurrency. This is a project to learn how to build containerised
applications.

## License

The packaging in this repository — Dockerfile, manifests, configuration, and
documentation — is licensed under the terms of the
[MIT License](https://github.com/ivuorinen/docker-xmrig/blob/main/LICENSE).

The **container image is not MIT licensed**. It contains XMRig, which is licensed
under the GNU General Public License v3.0, and which this build **modifies**
(`src/donate.h`, to disable the built-in donation). The image is therefore
conveyed under the GPL-3.0-or-later. See
[`NOTICE`](https://github.com/ivuorinen/docker-xmrig/blob/main/NOTICE); the same
file, the upstream licence, and the modified source ship inside the image under
`/usr/share/licenses/xmrig/`.

## Used works from other repositories

This repo is based on the work of:

- [jrkalf/xmrig-kryptokrona](https://github.com/jrkalf/xmrig-kryptokrona) for XMRIG for Kryptokrona
- [Roberto Meléndez](https://github.com/rcmelendez/xmrig-docker) for XMRIG for Monero
- [Bufanda](https://github.com/bufanda/docker-xmrig)

[config.json]: https://github.com/ivuorinen/docker-xmrig/blob/main/config.json
[docker-compose.yml]: https://github.com/ivuorinen/docker-xmrig/blob/main/docker-compose.yml
[deployment.yaml]: https://github.com/ivuorinen/docker-xmrig/blob/main/deployment.yaml
[tags]: https://hub.docker.com/r/ivuorinen/docker-xmrig/tags
