# Deploy LLMcalc

Two ways to run the production app:

| Target | Image | Where it builds | URL |
|---|---|---|---|
| Local Podman, Alpine | `Dockerfile` | Your machine | http://localhost:3000 |
| Local Podman, UBI | `Dockerfile.openshift` | Your machine | http://localhost:8080 |
| OpenShift | `Dockerfile.openshift` | A build pod on the cluster | the route printed by the script |

The Alpine image is the small local stack (`nginx:1.27-alpine` on port 80). The OpenShift image is one UBI image: `ubi9/nodejs-20` compiles the app during the build, and `ubi9/nginx-126` serves the static files on port 8080 as a non-root user.

```bash
./deploy/deploy.sh podman
./deploy/deploy.sh openshift -n llmcalc
```

## Local Podman

Podman Machine has to be running:

```bash
podman machine start
```

### Alpine image

This is the existing local stack. It does not use the OpenShift manifests.

```bash
podman compose up -d --build
```

Open http://localhost:3000.

```bash
podman compose logs -f
podman compose down
```

`docker compose up -d --build` does the same thing when Docker is the runtime. The container name is `llm-hardware-calculator`.

### UBI image

Same Dockerfile the cluster builds, run on your machine so you can check it before a cluster deploy. This uses port 8080 and the container name `llm-hardware-calculator-openshift`, so it does not replace the Alpine container on port 3000.

```bash
./deploy/deploy.sh podman
```

Open http://localhost:8080.

```bash
podman logs -f llm-hardware-calculator-openshift
podman rm -f llm-hardware-calculator-openshift
```

Use another host port if 8080 is taken:

```bash
./deploy/deploy.sh podman -p 8081
```

## OpenShift

The cluster builds the image. The script uploads this directory, runs `Dockerfile.openshift` in a build pod, pushes the result to an ImageStream in the project, and rolls out a Deployment, Service, and Route.

### Prerequisites

- `oc` logged in (`oc login`). Choose the project with `-n` or `oc project`, as described below.
- Permission to create BuildConfig, ImageStream, Deployment, Service, and Route in the project
- The Docker build strategy enabled for your user. If the build is rejected with a strategy error, a cluster admin grants it:

  ```bash
  oc adm policy add-cluster-role-to-user system:build-strategy-docker <user>
  ```

- The build pod must be able to pull these public images:
  - `registry.access.redhat.com/ubi9/nodejs-20`
  - `registry.access.redhat.com/ubi9/nginx-126`

  No Red Hat subscription is required for those two. A cluster that blocks `registry.access.redhat.com` needs a mirror or a pull secret on the `builder` service account.

### Select the project

OpenShift projects are namespaces. `-n` and `--namespace` choose the project for that run. The current `oc project` stays as it is.

```bash
oc project                          # project used when -n is omitted
oc get projects                     # projects you can deploy into
./deploy/deploy.sh openshift -n llmcalc
./deploy/deploy.sh openshift --namespace llmcalc
```

Create the project first when it does not exist yet:

```bash
oc new-project llmcalc
./deploy/deploy.sh openshift -n llmcalc
```

To make a project the default for later runs, switch to it and omit `-n`:

```bash
oc project llmcalc
./deploy/deploy.sh openshift
```

### Deploy

```bash
./deploy/deploy.sh openshift -n llmcalc
```

The first build takes a few minutes. The script streams the build log, waits for the rollout, and prints the route, for example `https://llm-hardware-calculator-llmcalc.apps.example.com`.

Run the same command again after code changes. It starts a new build and rolls out the new image.

### What gets created

| Object | Name | Purpose |
|---|---|---|
| ImageStream | `llm-hardware-calculator` | Stores the image built in this project. Local lookup is on, so the Deployment can use the short name. |
| BuildConfig | `llm-hardware-calculator` | Docker strategy, `Dockerfile.openshift`, binary source. Nothing builds until `oc start-build`. |
| Deployment | `llm-hardware-calculator` | One replica, container port 8080, probes on `/health`. An image trigger rolls it out when the ImageStream tag changes. |
| Service | `llm-hardware-calculator` | Port 8080 to the pod. |
| Route | `llm-hardware-calculator` | Edge TLS, HTTP redirected to HTTPS. |

Manifests live in `deploy/openshift/` and are applied with `oc apply -k deploy/openshift`.

The pod runs as whatever UID OpenShift assigns (always group 0). The Deployment does not set `runAsUser` or `runAsGroup`. The container drops all capabilities and cannot escalate.

### Useful commands

```bash
oc logs -f bc/llm-hardware-calculator -n llmcalc
oc logs -f deployment/llm-hardware-calculator -n llmcalc
oc get builds,pods,route -n llmcalc
oc describe buildconfig llm-hardware-calculator -n llmcalc
```

Remove the app from a project:

```bash
oc delete -k deploy/openshift -n llmcalc
```

### Cluster requirements that the image already meets

- Listens on 8080, which does not need extra privileges.
- Process user is `1001` in the image. OpenShift replaces that UID and keeps group 0.
- App files, logs, the pid file, and nginx temp directories are writable by group 0.
- `/health` returns `ok` for the readiness and liveness probes.
