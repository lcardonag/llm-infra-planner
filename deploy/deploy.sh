#!/usr/bin/env bash
# Build and deploy LLMcalc either to local Podman or to an OpenShift cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="llm-hardware-calculator"
PODMAN_IMAGE="${NAME}:openshift"
PODMAN_CONTAINER="${NAME}-openshift"
PORT="8080"
NAMESPACE=""

usage() {
  cat <<'EOF'
Usage: ./deploy/deploy.sh <podman|openshift> [options]

Build and deploy LLMcalc.

  podman       Build the UBI image with local Podman and run it on port 8080.
               Leaves the Alpine stack (podman compose, port 3000) alone.
  openshift    Upload this directory, build Dockerfile.openshift on the
               cluster, and roll out the deployment.

Options:
  -n, --namespace NAME   OpenShift project for this run. Does not change
                         the current `oc project`. Defaults to `oc project`.
  -p, --port PORT        Host port for the Podman container. Default: 8080.
  -h, --help             Show this help.

Examples:
  ./deploy/deploy.sh podman
  ./deploy/deploy.sh podman -p 8080
  ./deploy/deploy.sh openshift -n llmcalc
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  podman ps --format '{{.Ports}}' | grep -Eq ":${port}->"
}

wait_for_http() {
  local url="$1"
  local i
  for i in $(seq 1 30); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "timed out waiting for ${url}"
}

deploy_podman() {
  command -v podman >/dev/null 2>&1 || die "podman is not installed"
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  podman info >/dev/null 2>&1 || die "podman is not reachable; start the machine with: podman machine start"

  echo "Building ${PODMAN_IMAGE} with local Podman"
  podman build -f "${ROOT}/Dockerfile.openshift" -t "${PODMAN_IMAGE}" "${ROOT}"

  # Drop a previous copy of this container first so a re-run can reuse its port.
  podman rm -f "${PODMAN_CONTAINER}" >/dev/null 2>&1 || true
  if port_in_use "${PORT}"; then
    die "port ${PORT} is already in use. Stop that process or rerun with: ./deploy/deploy.sh podman -p PORT"
  fi

  echo "Starting ${PODMAN_CONTAINER} on port ${PORT}"
  podman run -d \
    --name "${PODMAN_CONTAINER}" \
    --restart unless-stopped \
    -p "${PORT}:8080" \
    "${PODMAN_IMAGE}"

  wait_for_http "http://127.0.0.1:${PORT}/health"
  echo "LLMcalc is running at http://localhost:${PORT}"
  echo "Logs:  podman logs -f ${PODMAN_CONTAINER}"
  echo "Stop:  podman rm -f ${PODMAN_CONTAINER}"
}

deploy_openshift() {
  command -v oc >/dev/null 2>&1 || die "oc is not installed"
  oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift; run: oc login"

  if [[ -z "${NAMESPACE}" ]]; then
    NAMESPACE="$(oc project -q)"
  fi
  [[ -n "${NAMESPACE}" ]] || die "no OpenShift project selected; pass -n NAME or run: oc project NAME"

  echo "Applying manifests in project ${NAMESPACE}"
  oc apply -k "${ROOT}/deploy/openshift" -n "${NAMESPACE}"

  echo "Starting cluster build from ${ROOT}"
  oc start-build "${NAME}" \
    --from-dir="${ROOT}" \
    --follow \
    --wait \
    -n "${NAMESPACE}"

  echo "Waiting for rollout"
  oc rollout status "deployment/${NAME}" -n "${NAMESPACE}" --timeout=300s

  local host
  host="$(oc get route "${NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}')"
  echo "LLMcalc is running at https://${host}"
  echo "Logs:  oc logs -f deployment/${NAME} -n ${NAMESPACE}"
  echo "Build: oc logs -f bc/${NAME} -n ${NAMESPACE}"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

TARGET="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      [[ $# -ge 2 ]] || die "missing value for $1"
      NAMESPACE="$2"
      shift 2
      ;;
    -p|--port)
      [[ $# -ge 2 ]] || die "missing value for $1"
      PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "${TARGET}" in
  podman) deploy_podman ;;
  openshift) deploy_openshift ;;
  -h|--help) usage ;;
  *) die "unknown target '${TARGET}'. Use podman or openshift." ;;
esac
