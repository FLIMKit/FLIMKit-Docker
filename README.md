# flimkit-docker

The Docker images for [FLIMKit](https://github.com/FLIMKit/FLIMKit). Each one runs FLIMKit with its [web UI](https://github.com/FLIMKit/flimkit-web-ui), so the whole application is used from a browser with nothing installed on the client.

These builds used to live in the FLIMKit repository, where an image could only be rebuilt by cutting a FLIMKit release. Here they rebuild on their own: on a FLIMKit release, weekly for base image and dependency updates, or by hand for any version.

## Images

```bash
docker run -d \
  -p 14500:14500 \
  -e FLIMKIT_PASSWORD=choose-a-password \
  -v /path/to/your/data:/data \
  -v /path/to/flimkit-config:/config \
  --name flimkit \
  alex1075/flimkit:latest
```

Then open **http://localhost:14500** and log in as `flimkit` with that password.

| Tag | Contents | Installed size |
|---|---|---|
| `latest` | FLIMKit and the web UI | ~1.4 GB |
| `desktop` | adds the noVNC desktop view on port 14501 | ~1.7 GB |
| `cellpose` | adds Cellpose and CPU torch, for "Apply cell mask" | ~2.4 GB |
| `cuda` | adds Cellpose and CUDA torch, `docker run --gpus all ...` | larger again |
| `rocm` | adds Cellpose and ROCm torch, `docker run --device /dev/kfd --device /dev/dri ...` | larger again |
| `accel-amd64` | `latest` plus the [accelerator add-on](https://github.com/FLIMKit/flimkit-accelerator-plugin)'s C kernels, for x86_64 CPUs | `latest` + ~0.1 MB |
| `accel-arm64` | the same on aarch64 (Graviton, Ampere, Apple silicon under Linux), built natively | `latest` + ~0.1 MB |
| `cuda-accel-amd64` | `cuda` plus the add-on's C kernels and its CUDA library | `cuda` + ~2.3 MB |
| `cuda-headless` | the bridge API instead of the web UI, with Cellpose and CUDA torch | ~270 MB less than `cuda` |
| `rocm-headless` | the same for AMD | ~270 MB less than `rocm` |

The three `accel` tags load the add-on from `/opt/flimkit-plugins` through `FLIMKIT_PLUGIN_PATH`, so free-τ fits use its C (and, on `cuda-accel-amd64` with `--gpus all`, CUDA) kernels without any setup. `FLIMKIT_FIT_BACKEND=cpu` turns it off. The CUDA library needs the host driver only.

GPU fitting in FLIMKit is torch, so every GPU image carries it whether or not Cellpose is installed.

Every tag is also published with its FLIMKit version, for example `0.13.5-latest` and `0.13.5-cuda`. Sizes are the unpacked filesystem measured inside the container; the download is smaller.

`latest` leaves out Cellpose and torch, which are over half the old image and are only needed by the Cellpose cell mask. Everything else — fitting, phasor, stitching, batch, the machine IRF builder — works there. Use `cellpose` if you want cell masking without a GPU.

It also leaves out the noVNC desktop, whose dependency tree (node, ghostscript, perl, a second system numpy) costs about 300 MB. `FLIMKIT_DESKTOP=1` therefore needs the `desktop` tag; on any other tag the container says so and carries on serving the web UI.

## Headless images

`cuda-headless` and `rocm-headless` serve [flimkit-bridge](https://github.com/FLIMKit/flimkit-bridge), the HTTP API that the QuPath and Fiji add-ons speak, instead of the browser UI. They carry no X server and no Tk, which is the right shape for a GPU node doing batch work or answering a viewer, rather than one showing somebody a browser.

```bash
docker run -d \
  --gpus all \
  --network host \
  -e FLIMKIT_BRIDGE_TOKEN=choose-a-token \
  -v /path/to/your/data:/data \
  --name flimkit-bridge \
  alex1075/flimkit:cuda-headless
```

**The bridge only answers requests whose `Host` header is `localhost` or `127.0.0.1`**, which is what stops a web page in your browser reaching it. That check is on the header, not the socket, so publishing a port and pointing a client at `http://gpu-box:8765` returns 403. Reach it either with `--network host` from the same machine, or over an SSH tunnel so the client sees `localhost`:

```bash
ssh -N -L 8765:localhost:8765 you@gpu-box
```

Set `FLIMKIT_BRIDGE_TOKEN` and give clients the same token; without it the bridge mints a new one each start and writes it to `~/.flimkit/bridge.json`, which a client in another container cannot read. `FLIMKIT_BRIDGE_PORT` moves the port.

## Settings

| Variable | Default | Effect |
|---|---|---|
| `FLIMKIT_PASSWORD` | not set | Password for the web UI (user `flimkit`) and for the desktop view. Without it, anyone who can reach the port can use FLIMKit and browse `/data`. |
| `FLIMKIT_DESKTOP` | `0` | Set to `1` to also serve the full desktop through noVNC on port 14501, for the few windows the web UI does not cover. Publish that port too. |
| `FLIMKIT_GEOMETRY` | `1440x900` | Size of the virtual screen FLIMKit draws on |
| `TZ` | `Etc/UTC` | Time zone for log timestamps |

Mount your data at `/data` and the config at `/config`, which is `HOME` in the image and where FLIMKit keeps expert settings, preferences and recent files. The images run as an arbitrary non-root user too, which is how TrueNAS starts them. The container reports healthy once the web UI answers on `/healthz`.

**TrueNAS SCALE (Custom App):** paste `docker-compose.yaml` from this repository, edit the volume paths to match your pool, and set `FLIMKIT_PASSWORD`.

## Building

```bash
docker build --build-arg FLIMKIT_VERSION=0.13.5 -t flimkit:test .
```

One Dockerfile builds every variant. `FLIMKIT_EXTRAS` chooses the FLIMKit extras (`gui` or `gui,cellpose`) and `TORCH_INDEX` picks the torch wheel index, or leaves torch out entirely when empty. `FLIMKIT_WEB_UI` is the web UI to install, currently the GitHub archive until that package reaches PyPI.

FLIMKit itself is installed from PyPI rather than copied from a checkout, so an image is reproducible from its tag and the build cannot race the release that publishes it.

## How builds are triggered

| Trigger | What it builds |
|---|---|
| `repository_dispatch` of type `flimkit-release` | The version in `client_payload.version`, sent by FLIMKit after it publishes to PyPI |
| Weekly schedule | The newest FLIMKit on PyPI, so base image updates ship without a release |
| `workflow_dispatch` | Any version you name, with an option not to push |
| Pull request | Builds and smoke-tests without pushing |

Every variant is started and checked before anything is pushed: `/healthz` answers, the API refuses a request without the password, and returns the application state with it.

The workflow waits for the version to appear on PyPI before building, so it can be triggered the moment a release is published.

## Licence

MIT, same as FLIMKit.
