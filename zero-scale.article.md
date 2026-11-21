# Zero-Scale Architecture for Java and Spring Boot on Kubernetes with KEDA, Traefik, and Project Leyden

## 1. Overview & Motivation

Running always-on Kubernetes workloads for bursty, internal, or low-traffic services wastes compute capacity—especially for Java Virtual Machine (JVM) services whose idle pods still reserve hundreds of megabytes of memory. A **zero-scale architecture** solves this by scaling an application's `Deployment` all the way down to `0` replicas when idle and spinning it back up on demand when traffic arrives.

Scaling down to zero is straightforward for **queue- or event-driven** workers: a message sits safely in Kafka, RabbitMQ, or Amazon Simple Queue Service (SQS) while Kubernetes Event-driven Autoscaling (KEDA) scales a consumer from `0` to `1`. 

However, for **Web/Hypertext Transfer Protocol (HTTP) workloads**, things get harder:

- Standard Kubernetes Horizontal Pod Autoscaler (HPA) cannot hold an incoming HTTP connection while a pod starts. If a `Deployment` has `0` replicas, an incoming request hits a `Service` with no endpoints and fails immediately with `503 Service Unavailable`.
- To make HTTP scale-to-zero transparent to callers, a lightweight component must stay in the request path, **intercept and buffer** the incoming HTTP request when the backend is at `0`, signal the autoscaler to wake the workload, wait for the pod's readiness probe to pass, and then forward the held request.

In this article, we build and run a complete local zero-scale stack on **`k3d`** combining:

- **Traefik Ingress** (built into `k3d`) for lightweight HTTP ingress routing
- **KEDA Core + the KEDA HTTP Add-on** (`InterceptorRoute` + `ScaledObject`) for HTTP request interception and scale-to-zero
- **Java 25 + Spring Boot 4.1 with Project Leyden Ahead-of-Time (AOT) Cache** to cut JVM cold-start latency
- **PostgreSQL deployed as a `StatefulSet`** backing a real task-organizer web application (`task-org-webapp`)

Later in Section 8, we also cover how this architecture behaves when deployed inside popular service meshes—specifically **Istio** and **Linkerd**.

---

## 2. Why Project Leyden AOT Cache Instead of GraalVM Native Image?

Whenever a service wakes from `0` replicas on an incoming HTTP request, **application startup time becomes user-visible latency**. If a caller or webhook provider enforces a tight timeout (for example, expecting `200 OK` within a few seconds), a slow traditional Just-In-Time (JIT)-compiled JVM cold start can turn a scale-from-zero event into a timeout.

**GraalVM Native Image** is frequently presented as the default answer for Java cold starts—and it does boot in tens of milliseconds. However, in many enterprise environments, moving to a GraalVM native binary introduces a major operational trade-off: **Application Performance Monitoring (APM) and observability tooling**.

Tools such as **Dynatrace OneAgent** (and similar bytecode-instrumenting Java agents) rely on standard JVM Tool Interface (JVMTI) / `-javaagent` bytecode instrumentation on the HotSpot JVM. Because GraalVM Native Image compiles Java ahead-of-time into a closed-world native binary without a standard HotSpot runtime, traditional Java agents cannot instrument it the same way—forcing teams to give up deep automatic tracing, profiling, or established operational workflows.

**Project Leyden AOT Cache** (standardized across Java 24 and Java 25 via Java Development Kit (JDK) Enhancement Proposals - [JEP 483](https://openjdk.org/jeps/483), [JEP 514](https://openjdk.org/jeps/514), and [JEP 515](https://openjdk.org/jeps/515)) offers a pragmatic middle ground:

| Approach | Cold-Start Speed | Standard HotSpot JVM & `-javaagent` (e.g., Dynatrace) | Build Complexity |
| :--- | :--- | :--- | :--- |
| Standard JVM (JIT) | Baseline | Full support | Low |
| **Java 25 Project Leyden AOT Cache** | **~2–2.5x faster Spring Boot startup** | **Full support** | **Low (one training run in `Dockerfile`)** |
| GraalVM Native Image | Fastest (~50–100 ms) | Limited / no standard JVM agent instrumentation | High (reachability metadata, longer builds) |

Because Project Leyden runs on the **standard HotSpot JVM**, you keep full compatibility with Dynatrace and other JVM agents while still cutting Spring Boot startup time by more than half.

---

## 3. Architecture Overview

The demo application, `task-org-webapp`, lets users organize tasks into projects. PostgreSQL runs as a `StatefulSet` at `1` replica backed by a PersistentVolumeClaim (PVC)—we deliberately keep the database running so database cold starts do not distort application scaling. Only `task-org-webapp` scales between `0` and `5` replicas.

```mermaid
flowchart TD
    Client["Browser / curl (localhost:8008)"]
    LB["k3d LoadBalancer"]
    subgraph k8s["Kubernetes Cluster"]
    ING["Traefik Ingress (k3s built-in)"]
    INT["KEDA HTTP Interceptor Proxy (keda)"]
    SCALER["KEDA External Scaler & Operator (keda)"]
    APP["task-org-webapp Deployment (0..5 replicas, Java 25 Leyden AOT)"]
    DB[("PostgreSQL StatefulSet 
       (1 replica + PVC)")]
    end

    Client --> LB --> ING --> INT
    INT -. "pending request metric" .-> SCALER
    SCALER -. "scale 0 <-> N via ScaledObject" .-> APP
    INT --> APP --> DB
    Client@{ shape: browser }
    style k8s text-align:left
```

### How the KEDA HTTP Add-on Fits In

The **KEDA HTTP Add-on** (`kedacore/http-add-on`) is an official companion chart installed alongside KEDA Core. Starting with v0.14+ (we use v0.16.0 here), the older `HTTPScaledObject` Custom Resource Definition (CRD) is replaced by two cleaner resources:

1. **`InterceptorRoute` (`http.keda.sh/v1beta1`):** Tells the KEDA HTTP Interceptor which incoming host/path to match, which backend Kubernetes `Service` to forward to, and what request-rate metric to report.
2. **`ScaledObject` (`keda.sh/v1alpha1`):** A standard KEDA `ScaledObject` targeting the `task-org-webapp` `Deployment` with `minReplicaCount: 0`, wired to the HTTP Add-on's external scaler via an `external-push` trigger.

When `task-org-webapp` is at `0` replicas, Traefik routes the request to `keda-add-ons-http-interceptor-proxy` on port `8080`. The Interceptor holds the HTTP request in memory, notifies the external scaler, waits for Kubernetes to schedule a pod and pass `/actuator/health/readiness`, and then forwards the request seamlessly.

---

## 4. Prerequisites & Local `k3d` Cluster Setup

We use two tools for local setup: [Homebrew](https://brew.sh/) and [mise-en-place](https://mise.jdx.dev/). Both work well on Linux, macOS, and Windows Subsystem for Linux (WSL). You also need [Docker](https://www.docker.com/) running locally.

### Install Command-Line Interface (CLI) Tools

Install `kubectl`, `k3d`, and `helm` (on Linux, Homebrew typically ships newer versions than operating system (OS) package managers):

```bash
brew install kubectl k3d helm
```

You can also install `k3d` and Java 25 with `mise`:

```bash
mise use k3d@latest
mise use java@temurin-25
```
> **Note:** Add `--global` if you want these tools installed for your entire system rather than just the current directory.

*(Other `k3d` installation options: [https://k3d.io/stable/#installation](https://k3d.io/stable/#installation))*

### Create the `k3d` Cluster

`k3d` ships with **Traefik Ingress** enabled on port `80` out of the box. We expose it on host port `8008` (avoiding conflict with local Spring Boot development on `8080`), and raise kubelet's image garbage-collection thresholds so locally imported images aren't evicted while the app is scaled to `0` on a busy disk:

```bash
k3d cluster create zero-scale \
  -p "8008:80@loadbalancer" \
  --k3s-arg "--kubelet-arg=image-gc-high-threshold=96@server:0" \
  --k3s-arg "--kubelet-arg=image-gc-low-threshold=92@server:0"
```

### Install KEDA Core and the KEDA HTTP Add-on

```bash
kubectl create namespace keda

helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --set image.pullPolicy=IfNotPresent \
  --wait \
  --timeout 10m

helm upgrade --install http-add-on kedacore/keda-add-ons-http \
  --namespace keda \
  --wait \
  --timeout 10m
```

*(All of the steps above—plus building, importing, and deploying the app—are automated in `scripts/setup-cluster.sh`.)*

---

## 5. The Demo Application (`task-org-webapp`)

The `task-org-webapp/` directory contains a **Spring Boot 4.1.2 / Java 25** application using:

- **Spring WebMVC** for the JavaScript Object Notation (JSON) Representational State Transfer (REST) Application Programming Interface (API) (`/api/projects`, `/api/projects/{projectId}/tasks`, `/api/tasks/{id}`)
- **Spring Data Java Database Connectivity (JDBC)** with PostgreSQL (`schema.sql` + idempotent `data.sql` seed data)
- **Spring Boot Actuator** exposing `/actuator/health/readiness` and `/actuator/health/liveness`
- **Bootstrap 5 via Content Delivery Network (CDN) + vanilla JavaScript (JS)** (`src/main/resources/static/index.html` and `app.js`) so the User Interface (UI) requires zero Node.js build tooling and adds no classpath overhead

### Making Leyden AOT Training Work Without a Live Database

During `docker build`, PostgreSQL is not running. Normally, Spring Data JDBC opens a JDBC connection at startup to auto-detect the Structured Query Language (SQL) dialect. To allow a clean, database-free AOT training pass—and also shave a database round-trip off every production cold start—we configure `JdbcPostgresDialect.INSTANCE` explicitly in `task-org-webapp/src/main/java/taskorg/JdbcConfig.java`:

```java
@Configuration
public class JdbcConfig extends AbstractJdbcConfiguration {

    @Override
    public JdbcDialect jdbcDialect(NamedParameterJdbcOperations operations) {
        return JdbcPostgresDialect.INSTANCE;
    }
}
```

Paired with `task-org-webapp/src/main/resources/application-aot-training.yaml` (which sets `spring.sql.init.mode: never` and `spring.datasource.hikari.initialization-fail-timeout: -1`), the application refreshes its full Spring context and exits cleanly with `-Dspring.context.exit=onRefresh` during image build.

### Multi-Stage `Dockerfile` with Project Leyden AOT Cache

In `task-org-webapp/Dockerfile`, Stage 1 builds and extracts the Spring Boot Java Archive (JAR) (`-Djarmode=tools ... extract`), and Stage 2 runs the Java 25 Project Leyden training pass to create `/app/app.aot`:

```dockerfile
FROM eclipse-temurin:25-jdk AS builder
WORKDIR /build

COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN chmod +x mvnw && ./mvnw dependency:go-offline -B

COPY src src
RUN ./mvnw package -DskipTests -B && \
    java -Djarmode=tools -jar target/task-org-webapp-0.0.1-SNAPSHOT.jar extract --destination /extracted

FROM eclipse-temurin:25-jre
WORKDIR /app

COPY --from=builder /extracted/ ./

RUN java -XX:AOTCacheOutput=app.aot \
         -Dspring.context.exit=onRefresh \
         -Dspring.profiles.active=aot-training \
         -jar task-org-webapp-0.0.1-SNAPSHOT.jar

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "task-org-webapp-0.0.1-SNAPSHOT.jar"]
```

Notice why `-XX:AOTCache=app.aot` is **not** hardcoded in `ENTRYPOINT`: by toggling `JAVA_TOOL_OPTIONS=-XX:AOTCache=app.aot` in the Kubernetes `Deployment`, we can benchmark baseline JVM vs. Leyden AOT on the exact same container image without rebuilding.

Build and import the image into `k3d`:

```bash
docker build -t task-org-webapp:latest task-org-webapp
k3d image import task-org-webapp:latest -c zero-scale
```

---

## 6. Deploying to Kubernetes

All manifests live under `k8s/` in numbered folders so you can apply them in order (or run `./scripts/deploy.sh`):

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-postgres/
kubectl rollout status statefulset/postgres -n task-org --timeout=180s

kubectl apply -f k8s/02-app/
kubectl rollout status deployment/task-org-webapp -n task-org --timeout=180s

kubectl apply -f k8s/03-keda/
kubectl apply -f k8s/04-ingress/
```

### Key Manifest Highlights

1. **PostgreSQL `StatefulSet` (`k8s/01-postgres/statefulset.yaml`):** Runs `postgres:17-alpine` with `replicas: 1`, a `1Gi` `volumeClaimTemplates` PVC, and a `pg_isready` readiness probe.
2. **App `Deployment` (`k8s/02-app/deployment.yaml`):** Enables Project Leyden via `JAVA_TOOL_OPTIONS: "-XX:AOTCache=app.aot"` and configures an aggressive readiness probe (`periodSeconds: 1`, `initialDelaySeconds: 0` against `/actuator/health/readiness`) so the KEDA Interceptor forwards traffic the moment Spring Boot is ready.
3. **KEDA `InterceptorRoute` + `ScaledObject` (`k8s/03-keda/`):**

```yaml
# k8s/03-keda/interceptor-route.yaml
apiVersion: http.keda.sh/v1beta1
kind: InterceptorRoute
metadata:
  name: task-org-webapp
  namespace: task-org
spec:
  target:
    service: task-org-webapp
    port: 8080
  rules:
    - hosts:
        - localhost
        - 127.0.0.1
      paths:
        - value: /
  scalingMetric:
    requestRate:
      targetValue: 5
      window: 1m
      granularity: 1s
```

```yaml
# k8s/03-keda/scaled-object.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: task-org-webapp
  namespace: task-org
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: task-org-webapp
  minReplicaCount: 0
  maxReplicaCount: 5
  pollingInterval: 5
  cooldownPeriod: 30
  triggers:
    - type: external-push
      metadata:
        scalerAddress: keda-add-ons-http-external-scaler.keda:9090
        interceptorRoute: task-org-webapp
```

4. **Traefik `Ingress` (`k8s/04-ingress/ingress.yaml`):** Created in the `keda` namespace so it can target `keda-add-ons-http-interceptor-proxy` directly without needing cross-namespace `ExternalName` workarounds:

```yaml
# k8s/04-ingress/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: task-org-ingress
  namespace: keda
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keda-add-ons-http-interceptor-proxy
                port:
                  number: 8080
```

---

## 7. Testing Scale-to-Zero & Benchmarking Cold Starts

Wait ~30 seconds with no traffic and watch `task-org-webapp` scale down to `0` while `postgres-0` stays `1/1 Running`:

```bash
kubectl get pods -n task-org -w
```

Now open [http://localhost:8008](http://localhost:8008) in your browser, or run our reproducible benchmark script:

```bash
./scripts/benchmark-cold-start.sh
```

The script toggles `JAVA_TOOL_OPTIONS` between unset (baseline JVM) and `-XX:AOTCache=app.aot` (Project Leyden), waits for `task-org-webapp` to scale to `0`, sends a cold-start `GET http://localhost:8008/api/projects`, and records both the end-to-end HTTP latency and Spring Boot's startup log line.

### Measured Results (Local `k3d` Cluster, Traefik + KEDA, Java 25, Spring Boot 4.1.2)

| Metric | Baseline JVM (no AOT cache) | Project Leyden AOT Cache (`-XX:AOTCache=app.aot`) | Improvement |
| :--- | :---: | :---: | :---: |
| **Spring Boot startup** (`Started TaskOrgWebappApplication`) | `2.496 s` *(process: `2.703 s`)* | **`0.986 s`** *(process: `1.128 s`)* | **~60% faster (2.5x)** |
| **Isolated container startup** (`docker run`, `onRefresh` exit) | `3.12 s` *(context: `1121 ms`)* | **`1.84 s`** *(context: `520 ms`)* | **~41% faster** |
| **End-to-end cold-start HTTP Time to First Byte (TTFB)** (0 -> 1 via Traefik + KEDA) | `4.22 s` *(HTTP 200)* | **`3.19 s`** *(HTTP 200)* | **~1.03 s faster (~24%)** |
| **Cold-start HTTP errors (`502`/`503`)** | `0` | **`0`** | Transparent wake-up |

### What the Numbers Tell Us

1. **Project Leyden delivers a dramatic JVM win with zero code or APM compromises:** Spring Boot startup drops from **2.50s to 0.99s** (under 1 second!), while still running on the standard HotSpot JVM where Dynatrace and other Java agents work out of the box.
2. **End-to-end cold start drops to ~3.19s:** The remaining ~2.2 seconds beyond Spring Boot's own startup comes from Kubernetes pod scheduling, container startup, readiness probe polling, and KEDA endpoint propagation.

---

## 8. Running Zero-Scale Inside a Service Mesh (Istio & Linkerd)

Our local `k3d` demo uses Traefik Ingress because **you do not need a service mesh to implement scale-to-zero**—KEDA and the KEDA HTTP Add-on handle all request buffering and scaling on their own.

In production, however, many Kubernetes platforms already run a service mesh such as **Istio** or **Linkerd** for mutual Transport Layer Security (mTLS), traffic splitting, and golden-signal telemetry. Both meshes work with KEDA's HTTP Add-on, with two important considerations: **control-plane exclusion** and **sidecar cold-start overhead**.

### Istio

- **Routing:** Point your Istio `Gateway` and `VirtualService` at `keda-add-ons-http-interceptor-proxy.keda.svc.cluster.local:8080` instead of directly at your application's `Service`. The KEDA Interceptor then forwards traffic to your meshed `task-org-webapp` Service.
- **Control-plane exclusion:** Disable sidecar injection on the `keda` namespace (`kubectl label namespace keda istio-injection=disabled`)—or configure KEDA's documented port-exclusion annotations—so Istio mTLS does not interfere with KEDA's internal metrics API server and admission webhooks.
- **Classic sidecar mode vs. Istio Ambient Mode:** In classic sidecar mode, every pod wake-up must also run `istio-init` and boot an Envoy (`istio-proxy`) sidecar before application traffic flows. In our earlier `k3d` tests with Istio sidecars enabled on this exact same app, end-to-end cold-start TTFB jumped from **~3.19s to ~7.27s**—adding roughly **4 seconds** of sidecar overhead on top of a sub-second Spring Boot startup. If cold-start latency is tight and you use Istio, **Istio Ambient Mode** eliminates per-pod sidecars by moving L4 mTLS to a shared node-level `ztunnel` (zero-trust tunnel), avoiding the per-pod Envoy startup tax altogether.

### Linkerd

- **Routing:** Linkerd intentionally does not bundle its own ingress controller; it pairs with your existing ingress (such as Traefik, NGINX, or Kubernetes Gateway API `HTTPRoute`), which routes to `keda-add-ons-http-interceptor-proxy` just like our demo.
- **Control-plane exclusion:** Keep the `keda` namespace unmeshed (`linkerd.io/inject: disabled`) so KEDA's webhooks and metrics server remain unaffected.
- **Lower sidecar cold-start overhead:** Unlike Istio's Envoy sidecar, Linkerd injects `linkerd2-proxy`, a purpose-built micro-proxy written in Rust. Because `linkerd2-proxy` has a much smaller memory footprint and faster startup than Envoy, its cold-start tax during `0 -> 1` scale-up is noticeably lower than classic Istio sidecar mode while still providing automatic mTLS and Layer 7 metrics.

### Choosing an Ingress / Mesh Topology for Zero-Scale

| Topology | Cold-Start Overhead | Mesh mTLS & Telemetry | Key KEDA Configuration |
| :--- | :--- | :--- | :--- |
| **Plain Ingress (Traefik / NGINX)** *(this demo)* | Lowest (~3.2s TTFB) | Ingress-only | Standard `Ingress` -> KEDA Interceptor |
| **Linkerd (sidecar)** | Low–Moderate (fast Rust proxy) | Full mesh mTLS + L7 metrics | `linkerd.io/inject: disabled` on `keda` |
| **Istio (Ambient Mode)** | Low (no per-pod sidecar) | Full mesh mTLS via node `ztunnel` | `Gateway`/`VirtualService` -> KEDA Interceptor |
| **Istio (classic sidecar)** | Highest (~7.3s TTFB in `k3d`) | Full mesh mTLS + Envoy features | `istio-injection=disabled` on `keda` |

---

## 9. Summary & Production Caveats

Combining **Traefik Ingress**, **KEDA Core + KEDA HTTP Add-on**, and **Java 25 Project Leyden AOT Cache** gives Java/Spring Boot teams a fast, observable zero-scale architecture on Kubernetes without giving up JVM APM instrumentation.

Before taking this pattern to production, keep four operational details in mind:

- **Readiness probe cadence:** A default `periodSeconds: 10` readiness probe can easily add 5–10 seconds of artificial delay after Spring Boot is already ready. Using `periodSeconds: 1` (or a Kubernetes `startupProbe` with a 1-second period) ensures the KEDA Interceptor forwards traffic immediately.
- **Cooldown period tuning:** We used `cooldownPeriod: 30` seconds for a snappy local demo. In production, set `cooldownPeriod` to several minutes (for example, `300`–`900` seconds) to avoid thrashing pods up and down between bursts.
- **Database connection pools:** When scaling from `0` to `N` pods under a sudden traffic spike, cap `spring.datasource.hikari.maximum-pool-size` conservatively (or place PgBouncer in front of PostgreSQL) so concurrent wake-ups do not exhaust PostgreSQL's `max_connections`.
- **Service mesh sidecar overhead:** If you run a sidecar-based service mesh in production, benchmark cold-start TTFB with sidecars enabled—as shown in Section 8, sidecar initialization can easily outweigh JVM startup time unless you tune sidecar startup or use a sidecarless data plane such as Istio Ambient Mode.
