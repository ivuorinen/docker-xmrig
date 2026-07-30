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
| `/log` | log directory, owned by uid `10001` |
| `:8080` | xmrig HTTP API, read-only, used by the healthcheck and probes |

The container runs as uid `10001`, not root.

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
    explicit value if you do not want that, or enable `tls`.
  - pass: ""

For all the available options,
visit [XMRig Config File](https://xmrig.com/docs/miner/config) documentation.

**Step 3:** Deploy the image as a standalone Docker container or
to a Kubernetes cluster.

### Docker

```bash
docker run -dit --rm \
    --volume "$(pwd)"/config.json:/etc/xmrig/config.json:ro \
    --volume "$(pwd)"/log:/log \
    --name xmrig ivuorinen/docker-xmrig:latest
```

The image's own `CMD` starts the miner; there is no need to pass a command.

If you prefer **Docker Compose**, edit the [`docker-compose.yml`][docker-compose.yml]
manifest as needed and run:

```bash
docker compose up -d
```

The Compose file limits the miner to **one CPU and 2 GB**. Without a limit xmrig
takes every core on the host indefinitely — raise it deliberately.

### Kubernetes

**Step 1:** Create a _namespace_ for our XMRig application (optional but recommended):

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

**Step 3:** Edit the [`deployment.yaml`](https://github.com/ivuorinen/docker-xmrig/blob/main/deployment.yaml) file. Things you may want to modify include:

- `image`: pin to a released tag from the [Tags](https://hub.docker.com/r/ivuorinen/docker-xmrig/tags) tab of the Docker Hub repo rather than running `:latest`.
- `replicas`: number of desired pods to be running. One pod is scheduled per node (see `affinity`), so this is capped by your node count.
- `resources`: set appropriate values for `cpu` and `memory` requests/limits.
- `affinity`: the manifest will schedule only one pod per node, if that's not the desired behavior, remove the `affinity` block.

**Step 4:** Once you are satisfied with the above manifest, create a _deployment_:

```bash
kubectl apply -f deployment.yaml
```

## Performance tuning

The shipped config disables the options that need privileges a container does not
get by default. They are worth enabling only if you can grant what they need:

| Option | Requires |
| --- | --- |
| `randomx.rdmsr` / `wrmsr` / `cache_qos` | x86 host with the `msr` kernel module, `--cap-add SYS_RAWIO`, `--device /dev/cpu`. No effect on arm64. |
| `randomx.1gb-pages` | host booted with `hugepagesz=1G`, plus a hugepage allocation for the container |
| `cpu.huge-pages` (on by default) | host `vm.nr_hugepages`, plus `--cap-add IPC_LOCK`. Falls back with a warning if unavailable. |

Left as shipped, xmrig runs correctly at a lower hashrate rather than failing.

## Logging

This Docker image sends the container logs to the `stdout`. To view the logs, run:

```bash
docker logs xmrig
```

For Kubernetes run:

```bash
kubectl logs --follow -n xmrig <pod-name>
```

### Persistent logging

Containers are stateless by nature, so their logs will be lost when they shut
down. `config.json` writes a copy to `/log/xmrig.log`; bind-mount that directory
to keep it on the host:

```bash
mkdir -p "$(pwd)"/log
sudo chown 10001 "$(pwd)"/log
```

The `docker run` command above and the [`docker-compose.yml`][docker-compose.yml]
file already include this mapping. On Kubernetes, replace the `log` `emptyDir` in
[`deployment.yaml`](https://github.com/ivuorinen/docker-xmrig/blob/main/deployment.yaml)
with a [Persistent Volume](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).

**xmrig does not rotate `xmrig.log`.** It grows until the filesystem fills. Either
rotate it on the host (`logrotate`) or drop `"log-file"` from `config.json` and
rely on `docker logs` / `kubectl logs`, which are rotated for you — the Compose
file caps the stdout log at 3 x 10 MB.

## Disclaimer

Use at your own disgression. This repository is by no means financial advise to mine
cryptocurrency. This is a project to learn how to build containerised applications.

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

This repo is a based on works of:

- [jrkalf/xmrig-kryptokrona](https://github.com/jrkalf/xmrig-kryptokrona) for XMRIG for Kryptokrona
- [Roberto Meléndez](https://github.com/rcmelendez/xmrig-docker) for XMRIG for Monero
- [Bufanda](https://github.com/bufanda/docker-xmrig)

[config.json]: https://github.com/ivuorinen/docker-xmrig/blob/main/config.json
[docker-compose.yml]: https://github.com/ivuorinen/docker-xmrig/blob/main/docker-compose.yml
