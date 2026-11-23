#!/usr/bin/env bash
# End-to-end check from your laptop: health, list buckets, upload, download, delete.
# Needs `make forward` running in another terminal. curl >= 7.75 (for --aws-sigv4).
set -euo pipefail
EP=${EP:-http://localhost:9000}
BUCKET=${BUCKET:-demo-bucket}
S3=(--user minioadmin:minioadmin --aws-sigv4 "aws:amz:us-east-1:s3")
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

check() {  # check <label> <expected> <actual>
  if [[ "$3" == "$2" ]]; then echo "ok    $1"; else echo "FAIL  $1: expected [$2], got [$3]"; exit 1; fi
}

check "health"   200 "$(curl -s -o /dev/null -w '%{http_code}' "$EP/minio/health/live")"
check "bucket $BUCKET exists" 200 "$(curl -s -o /dev/null -w '%{http_code}' -I "${S3[@]}" "$EP/$BUCKET")"
echo "hello from minio on k3d" > "$tmp"
check "upload"   200 "$(curl -s -o /dev/null -w '%{http_code}' "${S3[@]}" -T "$tmp" "$EP/$BUCKET/hello.txt")"
check "download" "hello from minio on k3d" "$(curl -s "${S3[@]}" "$EP/$BUCKET/hello.txt")"
check "delete"   204 "$(curl -s -o /dev/null -w '%{http_code}' "${S3[@]}" -X DELETE "$EP/$BUCKET/hello.txt")"
echo "All good."
