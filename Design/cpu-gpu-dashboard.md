# CPU+GPU differentiated inference dashboard — working plan

Branch `cpu+gpu_inference`. Underneath: Lazarus-931/mlx@pr/cpu-fast-path
(fork CPU fast path, = Marvis-Labs/mlx#1) and
Lazarus-931/mlx-vlm@cpu-gpu-support (--device selection), wired via
PythonDistribution requirements (dev only).

## Data path for device differentiation
1. Server: mlx_platform_server analytics writer gains a `device` column
   (gpu|cpu, from the --device the instance was launched with). Migration:
   nullable column, old rows render as "gpu".
2. NativAnalyticsStore: read `device`; ModelPerformance/ModelTokenPoint keyed
   by (modelID, device).
3. DashboardViewModel: split aggregates per device; expose `gpuPerformance` /
   `cpuPerformance` collections plus combined totals.
4. StatsView: device-sectioned panels (identical component, device badge),
   aggregate strip showing host CPU and GPU utilization side by side.
5. Menu bar extra: compact two-line readout (GPU x tok/s | CPU y tok/s) when
   both devices have activity in the last minute.

## Dev runtime shape
NativServerKit launches the GPU server as today; a settings toggle
(dualDeviceEnabled) additionally launches a CPU instance
(`--device cpu`, port +1) serving the same or a different model. The
instances API from Design/dual-device-api (POST/GET /v1/instances,
/v1/metrics, /v1/events SSE) replaces the two-process shape once
implemented server-side.
