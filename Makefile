CLUSTER ?= minio-lab

.PHONY: up cluster minio wait forward test ls down clean

## Everything: cluster + MinIO + bucket
up: cluster minio wait
	@printf "\nMinIO is ready. Next: 'make forward' in another terminal, then 'make test'.\n"

cluster:
	k3d cluster create $(CLUSTER) || true
	kubectl config use-context k3d-$(CLUSTER)

minio:
	kubectl apply -f k8s/minio.yaml

wait:
	kubectl -n minio rollout status deploy/minio --timeout=300s
	kubectl -n minio wait --for=condition=complete job/create-bucket --timeout=300s
	kubectl -n minio get pods

## Keep running in its own terminal: API on :9000, console on :9001
forward:
	@echo "API      http://localhost:9000"
	@echo "Console  http://localhost:9001   (minioadmin / minioadmin)"
	kubectl -n minio port-forward svc/minio 9000:9000 9001:9001

test:
	./scripts/smoke-test.sh

ls:
	./scripts/mc.sh ls -r local

## Stop the cluster but keep data (start again with: k3d cluster start $(CLUSTER))
down:
	k3d cluster stop $(CLUSTER)

## Delete the cluster and all data
clean:
	k3d cluster delete $(CLUSTER)
