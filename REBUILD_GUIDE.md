# Qwen worker: keep application edits separate from the model runtime

## What the available build log proves

The supplied build-log segment starts during dependency step `#12` at
2026-10-18 22:44:59 UTC and ends with a successful registry push at 23:10:04
UTC, a 25-minute-5-second observed segment (the log starts mid-build, so this
is not the full build duration). Its measured phases are:

- The shown Python dependency layer `#12`: 39.1 seconds.
- Four Qwen model downloads: 84.9 + 5.4 + 43.9 + 2.1 = 136.3 seconds.
- Image export step `#21`: 808.3 seconds total, including 576.2 seconds
  exporting layers.
- Build-cache export `#22`: 358.9 seconds.
- Registry push: 90.9 seconds for 38.53 GB.

So in this log segment, image export, cache export, and push account for about
20 minutes 58 seconds; weight downloads account for about 2 minutes 16 seconds.
The main measured delay is image export/cache/upload, not Python dependency
installation or model download alone. Runpod's current GitHub integration
documentation sets a separate 30-minute Docker-build timeout (and a 160-minute
total build window), so this excerpt was already close to the Docker-step
limit. A separate later user log reports a
38.52 GB push in 68.7 seconds; that is a different push-only measurement and
does not establish the duration of a full build, worker cold start, or warm
inference. Do not combine these runs.

Runpod documents two relevant deployment constraints: GitHub integration
stores the resulting image in Runpod's secure registry, and its image builder
does not support privately hosted base images. This means the app-only image
cannot simply use a private `registry.runpod.net` runtime as `FROM` in the
GitHub integration build. See [Runpod's GitHub deployment limitations](https://docs.runpod.io/serverless/workers/github-integration)
and [Docker registry deployment](https://docs.runpod.io/serverless/workers/deploy).

That same log identifies the pushed artifact as
`registry.runpod.net/ycoreai-qwen-image-edit-main-dockerfile:1088989a2` and
prints manifest digest
`sha256:cf380f92574c39a6c11a2a2c0c6bdc89904d50589e684c9cdc3fbd72851bcd08`.
Treat this only as a candidate base from that historical build. It does not
prove the current endpoint selects this image, and it does not prove that a
local Docker client can authenticate to Runpod's internal registry. A
read-only check from this laptop returned `401 Unauthorized`, so this candidate
is not currently usable by the local app-image builder. That response does not
prove the image is missing. Before building an app-only image, first make one
validated runtime image available from a registry that local Buildx can read
and the Serverless endpoint can pull. Runpod documents building/pushing from
Docker Hub and importing a registry image; use a public image only if its code
and model contents may be public, and never bake secrets into it. If the
existing internal image cannot be exported through an authorized route, the
alternative is a one-time full runtime build and push from the source Dockerfile
to the chosen registry. That one-time transfer can still be large; future
handler-only images can then reuse the immutable runtime digest.

The current RunPod endpoint's selected build source/image is not visible from
this repository. If it builds this branch using the default `Dockerfile`, code
changes still rebuild the all-in-one image. Repository files alone cannot
switch the endpoint to the app-only image.

## Image roles

- `Dockerfile` is the existing all-in-one build path. It remains the default
  fallback and includes the model/runtime installation.
- `Dockerfile.runtime` creates the large, infrequently rebuilt image with
  ComfyUI, extensions, dependencies, model weights, and the worker entrypoint.
- The image produced from `Dockerfile.runtime` is a **base layer only**, not
  a runnable Serverless release: it intentionally does not contain the current
  request handler or workflows. Never select the runtime image directly for an
  endpoint; build `Dockerfile.app` on top of its immutable digest first.
- `build_qwen_volume_runtime.ps1` can publish an optional no-model runtime;
  it requires a digest-pinned base image and reports the new runtime digest.
- `Dockerfile.app` creates a smaller application release from an already
  published immutable runtime image. It copies only `handler.py`, the workflow
  JSON files, the timing helper, `entrypoint.sh`, and the optional volume seeder.
- `build_qwen_app_image.ps1` builds and pushes that app image from Windows. It
  first verifies registry access to the immutable runtime digest, then builds
  and pushes. It requires Docker Desktop, registry login, and a new app-image
  tag. It does not update a RunPod endpoint.

## One-time setup required before app-only releases

1. In the RunPod build/release details, identify the exact image digest of the
   currently validated Qwen runtime. A build log saying “pushed successfully”
   is not itself the image reference or digest.
2. Ensure that exact image is available in a registry that your local Docker
   can pull from and the RunPod endpoint can access. If it is not, promoting or
   copying the runtime image is a one-time large image transfer. The local
   Docker engine must be running, and the destination registry must have room
   for the roughly 38 GB image.
   If the internal image cannot be exported, use the new one-time model-baked
   runtime publisher. Docker Hub lists the original public `linux/amd64` base
   image digest as
   `sha256:24d3f04f891ea8c3b783699b1e24801cb839e8c4c8b074a11f04e9eadf1110ff`
   ([Docker Hub image details](https://hub.docker.com/layers/wlsdml1114/multitalk-base/1.7/images/sha256-24d3f04f891ea8c3b783699b1e24801cb839e8c4c8b074a11f04e9eadf1110ff)).
   A read-only Buildx manifest check on this machine confirmed that exact
   public digest is currently readable. The local Docker engine still needs
   to be started before the image can be built.
   Build/publish a baseline runtime once to a registry RunPod can import:

   ```powershell
   Set-Location "D:\YCORE_AI_IMAGE_GENERATOR\qwen_image_edit_worker_branch"
   .\build_qwen_runtime.ps1 `
     -RuntimeBaseImage "docker.io/wlsdml1114/multitalk-base@sha256:24d3f04f891ea8c3b783699b1e24801cb839e8c4c8b074a11f04e9eadf1110ff" `
     -RuntimeImage "docker.io/<your-dockerhub-user>/ycore-qwen-runtime:v1"
   ```

   This needs Docker Desktop's Linux engine, a Docker Hub login for the
   destination, and enough local disk space. It may take a while and transfers
   the large image once. The script checks the pinned base and prints the
   immutable image digest; it does not alter a RunPod endpoint. Do not make the
   destination public unless you accept that the application and model files
   can be pulled by anyone. The build context ignores common env, key,
   certificate, and secrets paths; inspect local files before publishing. This
   runtime image is only a build base: it lacks `handler.py` and workflows and
   is not endpoint-ready by itself.
3. On Windows, log in to the selected registry using its approved credentials.
   Build/push an app image with a unique release tag:

   ```powershell
   Set-Location "D:\YCORE_AI_IMAGE_GENERATOR\qwen_image_edit_worker_branch"
   .\build_qwen_app_image.ps1 `
     -RuntimeImage "<registry>/<repository>@sha256:<64-character-digest>" `
     -AppImage "<registry>/<repository>:qwen-app-<unique-release-tag>"
   ```

   Replace the angle-bracket values with the verified references. The script
   rejects a runtime image without a SHA-256 digest, prints the pushed app
   image's immutable digest as `APP_IMAGE_DIGEST`, and does not mutate RunPod
   production. Use that digest for staging and preserve the old image for
   rollback.
4. Configure a **staging** Serverless endpoint to use the app image and verify
   1-, 2-, and 3-reference-image requests. Record the app image's immutable
   digest and retain the previous production image for rollback.
5. Only after staging passes, update the production endpoint's container image
   in RunPod to the verified app-image digest. If a staging endpoint is not
   available, do not treat a local Docker build as proof of endpoint behavior.

After setup, edits limited to `handler.py`, `comfy_timing.py`, workflow JSON, or entrypoint can
use the app-image build. Rebuild `Dockerfile.runtime` only when its base image,
Python/ComfyUI/custom-node dependencies, CUDA environment, or model weights
must change. RunPod still has to pull or activate the new image; this method
does not guarantee zero deployment delay.

## Model weights and Network Volume

The default runtime image still bakes Qwen weights into Docker layers.
Attaching a Network Volume alone does **not** remove those layers. The
repository has an opt-in volume path, but a volume has ongoing storage cost and
is not required for the app-only image approach above. Runpod recommends model
caching for Hugging Face models where supported; its endpoint cache currently
selects one model at a time, while this ComfyUI workflow uses four files from
multiple Hugging Face repositories. A Network Volume can hold all four, but
measure the transfer and billing tradeoff before choosing it. See [cached
models](https://docs.runpod.io/serverless/endpoints/model-caching), [volume
cache](https://docs.runpod.io/serverless/development/volume-cache), and [storage
options](https://docs.runpod.io/serverless/storage/overview). The repository's
opt-in volume path is:

1. RunPod Serverless mounts Network Volumes at `/runpod-volume`. Create one in
   the endpoint's data center and size it for all four source models plus
   working space. The worker now logs `QWEN_MODEL_ASSET` bytes per model and
   `QWEN_MODEL_ASSET_TOTAL` at startup; use those values from the current
   model-baked worker before choosing the volume size. The official standard
   tier currently lists $0.07/GB/month
   for the first 1 TB; actual billing and high-performance tiers may differ. A
   volume can constrain workers to that data center, and volumes in different
   data centers do not sync automatically.
2. Attach it to an isolated staging endpoint using the existing model-baked
   runtime, set `QWEN_MODEL_VOLUME_DIR=/runpod-volume/qwen-models` and
   `QWEN_SEED_MODEL_VOLUME=true`, and cap that staging endpoint at one worker
   while the one-time copy runs. The seed helper copies each model to a
   temporary destination, verifies SHA-256, and atomically renames it. Do not
   run multiple seeders against the same volume.
3. After the seed logs report `QWEN_VOLUME_SEED ... result=PASS`, publish the
   no-model runtime from a digest-pinned base:

   ```powershell
   Set-Location "D:\YCORE_AI_IMAGE_GENERATOR\qwen_image_edit_worker_branch"
   .\build_qwen_volume_runtime.ps1 `
     -RuntimeBaseImage "<registry>/<repository>@sha256:<64-character-digest>" `
     -RuntimeImage "<registry>/<repository>:qwen-volume-runtime-<release-tag>"
   ```

   The script builds with `QWEN_MODEL_STORAGE=volume` and prints the immutable
   digest. Attach the same volume and set
   `QWEN_MODEL_VOLUME_DIR=/runpod-volume/qwen-models`; leave
   `QWEN_SEED_MODEL_VOLUME=false`. Startup fails clearly if the mount or any
   model file is missing.
4. Build the app image from that immutable volume-runtime digest, validate on
   staging, and keep the previous image available for rollback.

This path is optional and does not change the default image unless the endpoint
sets the volume variables. No volume has been created, copied, or attached here.
Check the endpoint's data center, source model total, and current storage price
before creating one.

## Measure each phase separately

Record the same release's RunPod Build-tab phase durations, image size and
digest; then separately record first-job queue/cold-start time, worker startup
logs (`QWEN_TIMING`), and a second warm request. The handler logs prompt
submission, ComfyUI queue wait, execution (model loading plus inference), output
retrieval, and total job time. The ComfyUI websocket does not expose a reliable
separate model-load duration, so model loading and inference remain one metric.
Compare first and second requests using the same worker and note whether RunPod
reused that worker; otherwise they are not a cold/warm pair. No cold/warm
benchmark was provided in the evidence reviewed here.

The handler also treats matching ComfyUI `execution_error` and
`execution_interrupted` events as failed jobs immediately and closes the
WebSocket in a `finally` block. This prevents a failed prompt from leaving the
handler waiting for a completion event that will never arrive.

## Cost and safety limits

- No paid always-on workers, new volumes, endpoint changes, or live image jobs
  were started.
- A warm/minimum-active worker can reduce cold-start latency but can charge for
  idle compute; it needs an explicit cost decision before enabling.
- Keeping models inside an immutable runtime image can avoid rebuilding those
  layers for app-only releases, but it does not guarantee the registry or
  RunPod will never transfer/cache the large image again.
- The runtime Dockerfile still clones mutable ComfyUI/custom-node branches,
  installs version ranges, and downloads Hugging Face `main` URLs. The base
  image digest is pinned by the volume runtime builder, but that alone does not
  make the whole runtime reproducible. Do not call a new runtime build
  reproducible until those sources and model revisions/checksums are also pinned
  and validated.
