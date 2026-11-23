#!/usr/bin/env bash
# Run any mc (MinIO client) command from a throwaway pod inside the cluster.
#   ./scripts/mc.sh ls local
#   ./scripts/mc.sh ls -r local/demo-bucket
set -euo pipefail
kubectl -n minio run "mc-$RANDOM" --rm -i --restart=Never --quiet \
  --image=cgr.dev/chainguard/minio-client:latest \
  --env=MC_HOST_local=http://minioadmin:minioadmin@minio:9000 -- "$@"
