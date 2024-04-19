# My xmrig Miner

This is a simple miner that uses the xmrig miner to mine Monero.

The configuration is set to mine to my local p2pool node,
but you can change it to your own.

## What is XMRig?

[XMRig](https://xmrig.com/miner) is a high performance, open source, cross platform
RandomX, KawPow, CryptoNight and AstroBWT unified CPU/GPU miner
and RandomX benchmark. Official binaries are available for
Windows, Linux, macOS and FreeBSD.

## How to use this image

**Step 1:** Clone the GitHub repo:

```bash
git clone https://github.com/ivuorinen/docker-xmrig.git
```

**Step 2:** Edit the `config.json` file after cloning it.

- Provide your pool configuration:
  - url: your-p2pool-node:3333
  - user: your-miner-identifier
  - pass: ""

For all the available options,
visit [XMRig Config File](https://xmrig.com/docs/miner/config) documentation.

**Step 3:** Deploy the image as a standalone Docker container or
to a Kubernetes cluster.

### Docker

```bash
docker run -dit --rm \
    --volume "$(pwd)"/config.json:/xmrig/etc/config.json:ro \
    --volume "$(pwd)"/log:/xmrig/log \
    --name xmrig ivuorinen/docker-xmrig:latest \
    /xmrig/xmrig --config=/xmrig/etc/config.json
```

If you prefer **Docker Compose**, edit the [`docker-compose.yml`][docker-compose.yml]
manifest as needed and run:

```bash
docker-compose up -d
```

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

_remember to edit this file with your own pool configuration and wallet address
or it will mine against my anonymised docker wallet_

**Step 3:** Edit the [`deployment.yaml`](https://github.com/ivuorinen/docker-xmrig/blob/main/deployment.yaml) file. Things you may want to modify include:

- `replicas`: number of desired pods to be running. As I run a 3 worker node Turing Pi cluster, I run 3 replica's
- `image:tag`: to view all available versions, go to the [Tags](https://hub.docker.com/repository/docker/ivuorinen/docker-xmrig/tags) tab of the Docker Hub repo.
- `resources`: set appropriate values for `cpu` and `memory` requests/limits.
- `affinity`: the manifest will schedule only one pod per node, if that's not the desired behavior, remove the `affinity` block.

**Step 4:** Once you are satisfied with the above manifest, create a _deployment_:

```bash
kubectl -f apply deployment.yaml
```

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

Containers are stateless by nature, so their logs will be lost when they shut down.
If you want the logs to persist, enable XMRig syslog output in the [`config.json`][config.json] file:

```json
"syslog": true,
"log-file": "/xmrig/log/xmrig.log",
```

And give full permissions to the directory on the host machine:

```bash
chmod 777 "$(pwd)"/log
```

Then use either **Docker** [bind mounts](https://docs.docker.com/storage/bind-mounts/) or **Kubernetes** [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) to keep the log file on the host machine. The `docker run` command above and the [`docker-compose.yml`][docker-compose.yml] file already includes this mapping.

## Disclaimer

Use at your own disgression. This repository is by no means financial advise to mine
cryptocurrency. This is a project to learn how to build containerised applications.

## License

The Docker image is licensed under the terms of the [MIT License](https://github.com/ivuorinen/docker-xmrig/blob/main/LICENSE). XMRig is licensed under the GNU General Public License v3.0. See its [`LICENSE`](https://github.com/xmrig/xmrig/blob/master/LICENSE) file for details.

## Used works from other repositories

This repo is a based on works of:

- [jrkalf/xmrig-kryptokrona](https://github.com/jrkalf/xmrig-kryptokrona) for XMRIG for Kryptokrona
- [Roberto Meléndez](https://github.com/rcmelendez/xmrig-docker) for XMRIG for Monero
- [Bufanda](https://github.com/bufanda/docker-xmrig)

[config.json]: https://github.com/ivuorinen/docker-xmrig/blob/main/config.json
[docker-compose.yml]: https://github.com/ivuorinen/docker-xmrig/blob/main/docker-compose.yml
