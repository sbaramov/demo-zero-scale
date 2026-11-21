# Zero-Scale Architecture for Java & Spring Boot on Kubernetes

Companion repository for **[zero-scale.article.md](./zero-scale.article.md)**, demonstrating how to run a Java 25 / Spring Boot 4.1 web application in a **scale-to-zero** Kubernetes architecture using:

- **Traefik Ingress** (built into `k3d`) for lightweight HTTP ingress routing
- **KEDA Core + KEDA HTTP Add-on** (`InterceptorRoute` + `ScaledObject`) to buffer incoming HTTP requests and wake pods from `0` replicas without `502`/`503` errors
- **Java 25 Project Leyden AOT Cache** (`-XX:AOTCacheOutput` / `-XX:AOTCache`) to cut Spring Boot cold-start latency by >50% while staying on the standard HotSpot JVM (keeping APM agents such as Dynatrace working)
- **PostgreSQL 17 (`StatefulSet`)** backing a task-organizer web app (`task-org-webapp`)
- **`k3d`** for a lightweight local Kubernetes cluster

## Repository Layout

```text
.
├── zero-scale.article.md          # Main technical article (incl. Istio & Linkerd guidance)
├── task-org-webapp/               # Spring Boot 4.1 / Java 25 app + Leyden AOT Dockerfile
├── k8s/
│   ├── 00-namespace.yaml          # task-org namespace
│   ├── 01-postgres/               # PostgreSQL 17 StatefulSet, Service, Secret
│   ├── 02-app/                    # task-org-webapp Deployment + Service
│   ├── 03-keda/                   # KEDA HTTP Add-on InterceptorRoute + ScaledObject
│   └── 04-ingress/                # Kubernetes Ingress (Traefik) -> KEDA HTTP Interceptor
└── scripts/
    ├── setup-cluster.sh           # Create k3d cluster, install KEDA (+ HTTP Add-on), and deploy
    ├── deploy.sh                  # Rebuild image, import into k3d, and redeploy manifests
    ├── benchmark-cold-start.sh    # Measure baseline JVM vs. Project Leyden AOT cold starts
    └── delete-cluster.sh          # Tear down the local k3d cluster
```

## Quick Start

### Prerequisites

Docker plus `kubectl`, `k3d`, and `helm` (and Java 25 if running Maven tests locally):

```bash
brew install kubectl k3d helm
```

### Run the Demo Locally

```bash
# 1. Create the k3d cluster, install KEDA (+ HTTP Add-on), build and deploy
./scripts/setup-cluster.sh

# 2. Open the Task Organizer UI in your browser
#    http://localhost:8008

# 3. Benchmark cold-start latency (Baseline JVM vs. Project Leyden AOT Cache)
./scripts/benchmark-cold-start.sh

# 4. Rebuild & redeploy after code changes
./scripts/deploy.sh

# 5. Clean up the cluster when finished
./scripts/delete-cluster.sh
```

### Run Application Tests

```bash
cd task-org-webapp && ./mvnw test
```

## License

This project is licensed under the [MIT License](./LICENSE).
