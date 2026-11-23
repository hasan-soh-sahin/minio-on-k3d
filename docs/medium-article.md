# Run MinIO on Your Laptop with k3d: S3 in Five Minutes (and the Gotchas Nobody Mentions)

*A local, S3-compatible object store on Kubernetes, for testing data pipelines, Spark jobs, backups or anything else that speaks S3, without a cloud account.*

---

If you build anything that talks to S3, you eventually want a copy of S3 on your own machine. Cloud buckets cost money, need credentials and are slow to reset. MinIO gives you the same API locally. Running it on Kubernetes with k3d also means your local setup looks like the cluster your code will run on later.

This tutorial gets you from zero to a working bucket, then explains each piece and the problems I hit along the way. Every command here was run on a MacBook Air (Apple Silicon) in November 2026.

All the code is on GitHub: **[hasan-soh-sahin/minio-on-k3d](https://github.com/hasan-soh-sahin/minio-on-k3d)**

## What we're building

- **k3d** runs k3s, a lightweight Kubernetes, inside Docker containers. A cluster starts in about 20 seconds.
- **MinIO** runs as one pod in that cluster, with its data on a persistent volume.
- A one-shot **Job** creates a bucket called `demo-bucket`.
- A **port-forward** exposes the S3 API on `localhost:9000` and the web console on `localhost:9001`.

## Step 0: Install the tools

You need a Docker runtime, k3d and kubectl. On macOS:

```bash
brew install colima docker k3d kubectl
colima start          # or use Docker Desktop / OrbStack instead
```

Versions I used: k3d v5.9.0 (k3s v1.35.5), kubectl v1.37.1, Docker Engine 29.5 on Colima.

MinIO itself is light: it uses well under 100 MB of RAM at idle. The cluster adds a few hundred MB. Plan for about 1 GB of RAM and 2 GB of disk.

## Step 1: Clone and start

```bash
git clone https://github.com/hasan-soh-sahin/minio-on-k3d.git
cd minio-on-k3d
make up
```

`make up` does three things:

```bash
k3d cluster create minio-lab                 # 1. the cluster
kubectl apply -f k8s/minio.yaml              # 2. MinIO + bucket job
kubectl -n minio rollout status deploy/minio # 3. wait until it's ready
kubectl -n minio wait --for=condition=complete job/create-bucket
```

When it finishes you should see:

```
NAME                     READY   STATUS      RESTARTS   AGE
create-bucket-h2fc5      0/1     Completed   2          40s
minio-5bbc9c86ff-4txtq   1/1     Running     0          41s
```

The bucket job may restart a couple of times. That's expected: it starts at the same time as MinIO and retries until the server is ready.

## Step 2: Open it to your laptop

The MinIO service only has a cluster-internal address. Forward its ports in a second terminal and leave it running:

```bash
make forward
# same as: kubectl -n minio port-forward svc/minio 9000:9000 9001:9001
```

- S3 API: `http://localhost:9000`
- Web console: `http://localhost:9001` (log in with `minioadmin` / `minioadmin`)

## Step 3: Check that it works

```bash
make test
```

```
ok    health
ok    bucket demo-bucket exists
ok    upload
ok    download
ok    delete
All good.
```

The smoke test uses nothing but curl. Its first check, the health endpoint, needs no credentials:

```bash
curl -i http://localhost:9000/minio/health/live    # HTTP/1.1 200 OK
```

## Gotcha #1: "AccessDenied" doesn't mean it's broken

The first thing most people try is this:

```bash
curl http://localhost:9000
```

```xml
<Error><Code>AccessDenied</Code><Message>Access Denied.</Message>...</Error>
```

That's actually good news: MinIO is up and answering. Port 9000 is the S3 API, and every S3 request has to be signed with an access key (AWS Signature Version 4). An unsigned request is rejected.

curl 7.75 and later can sign requests:

```bash
curl --user minioadmin:minioadmin --aws-sigv4 "aws:amz:us-east-1:s3" http://localhost:9000/
# <ListAllMyBucketsResult>...<Name>demo-bucket</Name>...
```

In practice you'll use an S3 client instead.

**aws CLI:**

```bash
export AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://localhost:9000 s3 cp README.md s3://demo-bucket/
aws --endpoint-url http://localhost:9000 s3 ls s3://demo-bucket/
```

**Python (boto3):**

```python
import boto3

s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:9000",
    aws_access_key_id="minioadmin",
    aws_secret_access_key="minioadmin",
    region_name="us-east-1",
)

s3.put_object(Bucket="demo-bucket", Key="hello.txt", Body=b"hello from python")
print(s3.get_object(Bucket="demo-bucket", Key="hello.txt")["Body"].read().decode())
# hello from python
```

The only difference from real AWS is `endpoint_url`. The same applies to Spark (`fs.s3a.endpoint`), Terraform, rclone and most other S3 tools. Some of them also need **path-style access** turned on (`fs.s3a.path.style.access=true` in Spark), because `demo-bucket.localhost` doesn't resolve.

## Gotcha #2: The official images are gone from Docker Hub

Most MinIO tutorials use `minio/minio` and `minio/mc`. At the time of writing, both fail to pull:

```
Failed to pull image "minio/minio:latest": pull access denied,
repository does not exist or may require authorization
```

The pod sits in `ImagePullBackOff` forever. Copies on quay.io and Bitnami failed the same way for me. What still works is Chainguard's builds:

| Role | Old image | Working image |
|---|---|---|
| Server | `minio/minio` | `cgr.dev/chainguard/minio:latest` |
| Client (mc) | `minio/mc` | `cgr.dev/chainguard/minio-client:latest` |

The server image is a drop-in replacement. The client needs one change: Chainguard images are minimal and have **no shell**, so the usual trick fails:

```yaml
# Doesn't work: there's no /bin/sh in the image
command: ["/bin/sh", "-c", "mc alias set local http://minio:9000 ... && mc mb local/demo-bucket"]
```

Instead, define the alias with an environment variable. `mc` reads any `MC_HOST_<alias>` variable as a connection string. The image's entrypoint is already `mc`, so `args` holds only the mc arguments:

```yaml
image: cgr.dev/chainguard/minio-client:latest
env:
  - { name: MC_HOST_local, value: "http://minioadmin:minioadmin@minio:9000" }
args: ["mb", "--ignore-existing", "local/demo-bucket"]
```

`--ignore-existing` makes the job safe to re-run.

The same trick gives you an `mc` shell into the cluster without installing anything:

```bash
kubectl -n minio run mc --rm -i --restart=Never \
  --image=cgr.dev/chainguard/minio-client:latest \
  --env=MC_HOST_local=http://minioadmin:minioadmin@minio:9000 -- ls -r local
```

That's what `scripts/mc.sh` in the repo wraps.

## Inside the manifest

`k8s/minio.yaml` has six objects. Here's why each one is there.

**Namespace `minio`** keeps everything together. `kubectl delete ns minio` removes it all.

**Secret `minio-creds`** holds `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`. The Deployment loads them with `envFrom`. Keeping them out of the pod spec means changing them is a one-line edit.

**PersistentVolumeClaim `minio-data`** asks for 5 Gi. k3s ships a `local-path` storage class, so the claim binds without any extra setup. Because of this volume, your buckets survive pod restarts. I tested this by deleting the pod: the bucket was still there when the new pod came up. If you'd rather start clean on every restart, replace it with `emptyDir: {}`.

**Deployment `minio`** runs the server:

```yaml
args: ["server", "/data", "--console-address", ":9001"]
```

Without `--console-address`, the console picks a random port, which is hard to forward. Two more details matter here:

- `strategy: Recreate`: the volume is ReadWriteOnce, so the old pod must stop before a new one starts.
- Readiness and liveness probes on `/minio/health/ready` and `/minio/health/live`. `kubectl rollout status` waits until MinIO actually answers, not just until the container starts.

**Service `minio`** gives the pod a stable name. Other pods reach it at `http://minio.minio.svc.cluster.local:9000`, or just `http://minio:9000` from the same namespace.

**Job `create-bucket`** runs `mc mb` once. `backoffLimit: 20` covers the few seconds before MinIO is ready.

## Gotcha #3: Your laptop's disk

This isn't specific to MinIO, but it cost me more time than everything else combined.

On macOS, containers run inside a Linux VM, and the VM's disk is a single file on your Mac. That file grows as you pull images, but **it doesn't shrink when you delete them**. My Mac reached 100% full. Docker then started failing with errors that don't look like a disk problem at all:

```
failed to create temp dir: mkdir /tmp/containerd-mount...: input/output error
```

If you see I/O errors from Docker, check your free space first:

```bash
df -h /System/Volumes/Data
docker system df
```

Fixes, from least to most effort:

1. **Free space on your Mac,** then restart the runtime (`colima restart`, or quit and reopen Docker Desktop).
2. **Remove what you don't need:** `docker image prune`, old images, stopped containers. Space freed inside the VM can be reused right away, but it only comes back to macOS after a trim (`colima ssh -- sudo fstrim -av`) or a VM rebuild.
3. **Move the VM to an external disk.** For Colima, the VM lives in `~/.colima`:

   ```bash
   colima stop
   cp -R ~/.colima /Volumes/External/colima     # disk must be APFS, not exFAT
   mv ~/.colima ~/.colima.bak
   ln -s /Volumes/External/colima ~/.colima
   colima start                                 # then delete ~/.colima.bak
   ```

   The copy can be much bigger than `du ~/.colima` suggests. The VM disk is a sparse file, and copying it to another volume writes it at full size (100 GB for me, versus 24 GB actually used), so expect it to take a while.

   Keep the disk plugged in and stop macOS from putting it to sleep. If it disconnects while the VM is running, Colima shows `Broken`. Reconnect the disk and run `colima stop --force && colima start`.

A spinning USB hard drive works, but a USB SSD is much faster for image pulls and builds.

## Cleaning up

```bash
make down    # stop the cluster, keep the data; resume with: k3d cluster start minio-lab
make clean   # delete the cluster and all data
```

## Where to go from here

- **Point your app at it.** Set the endpoint to `http://localhost:9000` from your laptop, or to `http://minio.minio.svc.cluster.local:9000` from inside the cluster.
- **Add more buckets.** Add more `mb` commands to the Job, or run `./scripts/mc.sh mb local/another-bucket`.
- **Pin the images.** Chainguard's free tier only offers `:latest`. For a demo that must keep working, pin the image digest.
- **Don't take this to production.** Default credentials, one replica and no TLS are fine on a laptop and nowhere else.

The full setup is about 100 lines of YAML and a Makefile: **[github.com/hasan-soh-sahin/minio-on-k3d](https://github.com/hasan-soh-sahin/minio-on-k3d)**. If one of these gotchas saved you an afternoon, a clap or a star helps others find it.
