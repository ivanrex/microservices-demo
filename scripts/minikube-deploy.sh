#!/usr/bin/env bash
set -euo pipefail

# ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../microservices-demo" && pwd)"
ROOT_DIR="${HOME}/microservices-demo"
MANIFEST="${ROOT_DIR}/release/kubernetes-manifests.yaml"

IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d.%H%M%S)}"
APPLY=true

for arg in "$@"; do
  case "$arg" in
    --no-apply)
      APPLY=false
      ;;
  esac
done

SERVICES=(
  adservice
  cartservice
  checkoutservice
  currencyservice
  emailservice
  frontend
  loadgenerator
  paymentservice
  productcatalogservice
  recommendationservice
  shippingservice
  shoppingassistantservice
)

echo "Using image tag: ${IMAGE_TAG}"
eval "$(minikube -p minikube docker-env)"

for svc in "${SERVICES[@]}"; do
  svc_dir="${ROOT_DIR}/src/${svc}"
  if [[ "${svc}" == "cartservice" ]]; then
    svc_dir="${ROOT_DIR}/src/${svc}/src"
  fi
  echo $svc_dir
  if [[ -f "${svc_dir}/Dockerfile" ]]; then
    echo "Building ${svc}:${IMAGE_TAG}"
    docker build -t "${svc}:${IMAGE_TAG}" "${svc_dir}"
  else
    echo "Skipping ${svc} (no Dockerfile at ${svc_dir})"
  fi
done

python - <<PY
from pathlib import Path
import re

manifest = Path("${MANIFEST}")
text = manifest.read_text()


services = "${SERVICES[@]}".split()
tag = "${IMAGE_TAG}"

def replace_image_line(line):
    for svc in services:
        if svc in line:
            indent = re.match(r'^(\\s*)', line).group(1)
            return f"{indent}image: {svc}:{tag}"
    return line

out_lines = []
for line in text.splitlines():
    if re.match(r'^\\s*image:\\s*', line):
        out_lines.append(replace_image_line(line))
    else:
        out_lines.append(line)

manifest.write_text("\\n".join(out_lines) + "\\n")
print(f"Updated {manifest} images to tag {tag}")
PY

echo "MANIFEST update complete."
if [ "${APPLY}" = true ]; then
  kubectl apply -f "${MANIFEST}"
else
  echo "Skipping kubectl apply (--no-apply)"
fi
