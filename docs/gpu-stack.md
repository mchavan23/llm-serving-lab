# How a GPU reaches a container on this node

Notes written against a rented Scaleway L40S, 2026-09-20 (session 1). Every
statement below was observed on that host, not taken from documentation.

## 1. The layers, bottom to top

    hardware        NVIDIA L40S, 48 GB board, ~45 GiB usable, compute capability 8.9
    kernel driver   nvidia.ko + userspace libs -- version 580.126.20
    CUDA runtime    ships INSIDE the container image, not on the host
    container hook  nvidia-container-toolkit: injects devices + libs at start
    runtime config  per-stack: Docker, host containerd, k3s containerd
    orchestrator    k8s sees GPUs only as an advertised resource
    workload        vLLM

The single most useful idea: **the host provides the driver, the container
provides the CUDA runtime.** That is why one host can run CUDA 12 and CUDA 13
containers at once, and why the vLLM image is 30 GB.

### Driver vs CUDA runtime vs CUDA toolkit

- **Driver** (580.126.20) -- kernel module plus `libcuda.so`. Host only.
- **CUDA runtime** (`libcudart`, cuBLAS, cuDNN) -- userspace libraries, shipped
  in the image. This is most of vLLM's 30 GB.
- **CUDA toolkit** -- compilers (`nvcc`). Not needed at inference time.

`nvidia-smi` prints `CUDA Version: 13.0`. That is the **highest** runtime this
driver supports, not what is installed. Compatibility runs one way: a newer
driver runs older CUDA containers; an older driver cannot run newer ones.
This is why `ubuntu_noble_gpu_os_13_nvidia` was chosen -- it is the permissive
end of that relationship.

### Compute capability

`8.9` = Ada Lovelace. It is the hardware feature level, not a version number.
8.9 has native FP8 tensor cores; 8.0/8.6 do not and would emulate. This is the
fact that makes the FP8 benchmark leg meaningful rather than theatre.
Confirmed with:

    nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader
    NVIDIA L40S, 8.9

## 2. The container toolkit is a hook, not a runtime

`nvidia-container-runtime` is a thin shim in front of `runc`. On container
start it injects the device nodes (`/dev/nvidia*`) and bind-mounts the host's
driver libraries into the container. Without it a container sees no GPU even
though the driver is loaded and the card is idle.

It has to be registered separately with **each** container stack, because each
reads its own config file:

| stack | config file | state on the Scaleway image |
|---|---|---|
| Docker | `/etc/docker/daemon.json` | nvidia registered AND `default-runtime` |
| host containerd | `/etc/containerd/config.toml` | **no nvidia entry at all** |
| k3s containerd | `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` | does not exist yet |

Consequence measured in session 1: `docker run` gets the GPU with no flags at
all, because nvidia is Docker's *default* runtime. Nothing the vendor image
ships helps k3s. k3s regenerates its containerd config from a template at every
start, so the supported way in is to write `config.toml.tmpl` -- which is what
`cluster/setup-gpu.sh` step 3 does.

## 3. Two ways to advertise the GPU to Kubernetes

Kubernetes does not discover GPUs. Something must publish
`nvidia.com/gpu` into `node.status.allocatable`, and the scheduler then treats
it as a countable resource like CPU or memory.

- **NVIDIA device plugin** -- one DaemonSet. Chosen as the default for P1: if a
  pod cannot see the card, the fault is the host or k3s's containerd, not a
  ten-pod operator.
- **GPU Operator** -- Helm chart managing driver, toolkit, plugin, DCGM and
  more. Here `driver.enabled=false` and `toolkit.enabled=false`, since the image
  supplies both, and it needs `CONTAINERD_CONFIG`/`CONTAINERD_SOCKET` pointed at
  k3s's paths.

**The measured benchmark sweep must not change stack mid-flight.** Numbers from
two platform configurations are not comparable, and week 6 has to name which
one produced them.

### RuntimeClass, and why `--set-as-default` matters

`RuntimeClass` is the Kubernetes object that lets a pod ask for a named
containerd runtime handler:

    spec:
      runtimeClassName: nvidia

KServe's `ClusterServingRuntime` CRD (v0.20.0) has **no** `runtimeClassName`
field. `InferenceService` does expose `spec.predictor.runtimeClassName`, but
relying on it means every ISVC must remember it, and forgetting produces a pod
that starts and then cannot find a GPU. Hence `--set-as-default=true`: make
nvidia the node's default handler so a pod gets the GPU whether it asks or not.

Note the asymmetry this creates in testing: `setup-gpu.sh`'s smoke pod sets
`runtimeClassName: nvidia` explicitly, so it passes even in a state where a
KServe predictor pod would fail. A green smoke test is not proof the default
handler is correct.

## 4. What vLLM does at startup

Observed cold start, FP8 leg, t0 to serving: ~115 s.

    weights download        18.4 s   8.47 GiB, ~460 MB/s
    model load              22.3 s   8.51 GiB resident
    torch.compile           25.7 s   Inductor, cached to disk afterwards
    profile + KV + warmup   40.7 s   total for engine init
    KV cache                205,856 tokens -> 50.26x concurrency at 4,096

Key lines from the log worth being able to read:

    Selected CutlassFP8ScaledMMLinearKernel for CompressedTensorsW8A8Fp8
    Using FLASH_ATTN attention backend out of potential backends: [...]

The first names the **kernel**: CUTLASS FP8 GEMM, native on cc 8.9. The 4-bit
legs are expected to land on **Marlin** kernels instead; if both AWQ and GPTQ
dispatch to Marlin, the throughput delta may be small, and that is a result.

vLLM reads `quantization_config` from the checkpoint. No `--quantization` flag
is passed anywhere in this project -- the checkpoint decides, which is what the
Phase A repo audit verified.

### The two controlled variables

    --max-model-len=4096
    --gpu-memory-utilization=0.80

`max-model-len` is set explicitly because unset is NOT neutral: vLLM would read
131072 from Llama 3.1's `config.json` and refuse to start, because the KV cache
cannot hold a single max-length sequence.

`gpu-memory-utilization` is a fraction of total VRAM for weights plus KV cache.
Raising it later invalidates every leg already measured. Note the engine's own
warning: with CUDA-graph memory profiling (default since v0.21.0), `0.80` is
effectively `0.7909`. Consistent across legs, so comparability holds -- but the
report must state it.

## 5. The disk consequence nobody budgets for

Docker's image store and k3s's containerd image store are **separate**. The same
30.49 GB vLLM image pulled into both costs ~60 GiB of a 135 GiB filesystem.
Delete the Docker copy once k3s has its own; do not grow the volume.

## 6. Commands that answer each question

    nvidia-smi --query-gpu=name,compute_cap,memory.total,driver_version --format=csv
    cat /etc/docker/daemon.json
    grep -n nvidia /etc/containerd/config.toml
    kubectl get nodes -o jsonpath='{.items[0].status.allocatable}'
    kubectl get runtimeclass
    docker system df
    curl -s localhost:8000/metrics | grep vllm:num_requests_waiting
