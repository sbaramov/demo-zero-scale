# Zero-Scale Java/Spring Boot Architecture Article & Demo — Design Document

**Date:** 2026-11-18
**Status:** Draft (pending review & approval)
**Repository:** `/home/sbaramov/Development/personal/article-zero-scale`

---

## 1. Intent and the Why

This repository produces a hands-on technical article ([zero-scale.article.md](file:///home/sbaramov/Development/personal/article-zero-scale/zero-scale.article.md)) backed by a working, locally runnable Kubernetes demo that shows Java/Spring Boot engineers how to build a **scale-to-zero architecture** without sacrificing production observability.

**Core narrative:**
- Scaling an HTTP-facing service to `0` replicas saves compute cost for bursty or low-traffic workloads, but standard Kubernetes HPA cannot hold incoming HTTP requests while a pod wakes up. Pairing **Istio Service Mesh** with **KEDA Core + the KEDA HTTP Add-on** (`InterceptorRoute` + `ScaledObject`) solves the traffic-interception and scale-from-zero problem cleanly.
- Once a workload scales from zero on demand, **cold-start latency** becomes user-visible. While GraalVM Native Image is often pitched as the default answer for Java cold starts, native binaries break or severely limit standard JVM APM instrumentation (such as **Dynatrace OneAgent**).
- **Project Leyden AOT Cache** (in Java 25 + Spring Boot 4.1) offers a compelling alternative: it cuts cold-start times substantially while staying on the standard HotSpot JVM, preserving full Java agent and APM compatibility.

---

## 2. Goals, Non-Goals, and Anti-Goals

### Goals
1. **End-to-end local reproducibility on `k3d`:** A reader with Docker, Homebrew, and/or `mise` can spin up a local `k3d` cluster, install Istio and KEDA (+ HTTP Add-on), deploy Postgres and `task-org-webapp`, and watch the app scale to `0` when idle and wake from `0` on an incoming HTTP request without errors.
2. **Real, usable demo app (`task-org-webapp`):** A lightweight Spring Boot 4.1.2 / Java 25 web application for organizing tasks across projects, backed by PostgreSQL deployed as a `StatefulSet`, with a clean Bootstrap 5 UI and a JSON REST API.
3. **Measurable Project Leyden AOT Cache improvement:** A single container image containing a build-time generated `app.aot` cache, allowing readers to toggle AOT caching on and off (e.g., via `JAVA_TOOL_OPTIONS`) and measure cold-start latency side-by-side (`curl` / pod startup logs).
4. **Complete, publication-ready article ([zero-scale.article.md](file:///home/sbaramov/Development/personal/article-zero-scale/zero-scale.article.md)):** Explains the architecture, the Istio + KEDA HTTP Add-on mechanics, the Leyden-vs-GraalVM (APM/Dynatrace) trade-off, and walks step-by-step through the exact commands and YAML in the repository.

### Non-Goals
- **GraalVM native image build in the demo:** Mentioned conceptually in the article to frame the APM/Dynatrace trade-off, but not built or deployed in this repository.
- **Scaling PostgreSQL to zero:** Postgres runs as a `StatefulSet` at `1` replica with persistent storage. Scaling the database to zero would dominate cold-start latency and distract from the application architecture.
- **Authentication, multi-tenancy, or production hardening:** No user login, RBAC, TLS certificate management (cert-manager), or multi-node HA tuning.
- **Complex frontend build pipeline:** No Node.js/npm/Vite/React toolchain.

### Anti-Goals (what would make this fail even if it technically works)
- **Magic/hidden YAML or build steps:** Hiding the Leyden `-XX:AOTCacheOutput` / `-XX:AOTCache` flags inside buildpacks or burying Istio/KEDA manifests inside Helm templates would defeat the educational purpose of the article.
- **Flaky cold starts returning 502/503:** If the KEDA HTTP Interceptor forwards traffic before Spring Boot is genuinely ready to serve requests, or if Istio sidecar injection breaks KEDA's control plane, the demo fails its central promise.
- **Article/code drift:** Every command, manifest, and measurement described in `zero-scale.article.md` must match the actual files and verified behavior in the repo.

---

## 3. Constraints

- **Existing scaffold:** [task-org-webapp/pom.xml](file:///home/sbaramov/Development/personal/article-zero-scale/task-org-webapp/pom.xml) is already initialized with **Spring Boot `4.1.2`**, **Java `25`**, `spring-boot-starter-webmvc`, `spring-boot-starter-data-jdbc`, and `org.postgresql:postgresql`.
- **Local environment:** Linux/macOS/WSL with `docker`, `k3d`, `kubectl`, `helm`, `istioctl`, `java 25`, `mvn` (or `./mvnw`), installed via Homebrew and/or `mise`.
- **Istio + KEDA coexistence:** KEDA's control-plane pods (`keda` namespace) must have Istio sidecar injection disabled (`istio-injection=disabled`) so Istio mTLS does not break KEDA's internal API service / admission webhooks.
- **KEDA HTTP Add-on API:** Uses the current v0.14+ resources—`InterceptorRoute` (`http.keda.sh/v1beta1`) paired with a standard KEDA `ScaledObject` (`keda.sh/v1alpha1`, `external-push` trigger)—rather than the deprecated `HTTPScaledObject`.
- **Leyden AOT training without a live DB:** The Docker build runs `java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar ...` in an isolated build stage where PostgreSQL is not running. Spring Boot's datasource / schema initialization must be configured so the training run succeeds cleanly without failing on a missing database connection (e.g., lazy datasource initialization / `spring.sql.init.mode=never` during the training profile, while enabled in the Kubernetes runtime environment).
- **k3d port / ingress conflict:** `k3d` ships with Traefik by default on port 80; the `k3d` cluster should be created with Traefik disabled (`--k3s-arg "--disable=traefik@server:0"`) so Istio's Ingress Gateway owns HTTP ingress cleanly.

---

## 4. Approaches Considered

### Approach A: Explicit `Dockerfile` (single toggleable Leyden image) + Bootstrap 5 Static HTML/JS + Plain K8s YAML *(Selected)*
- **What it is:** Spring Boot REST API + Spring Data JDBC + static `index.html` styled with Bootstrap 5 (CDN) and minimal vanilla JS; one multi-stage `Dockerfile` producing an extracted JAR + `app.aot` with runtime AOT toggle via `JAVA_TOOL_OPTIONS`; plain, readable K8s manifests in `k8s/` plus setup scripts.
- **Trade-offs:** Maximum clarity for readers (exact `java` AOT flags, raw Istio/KEDA YAML, easy `curl` cold-start timing, zero frontend build tooling). Slightly more explicit `kubectl apply` commands than an umbrella Helm chart.

### Approach B: Thymeleaf + HTMX + Kustomize Overlays (`jvm` vs. `leyden`)
- **What it is:** Server-rendered HTML fragments via Thymeleaf + HTMX, two Docker targets, and Kustomize overlays to switch between JVM and Leyden.
- **Trade-offs:** Idiomatic for JS-averse Java devs, but introduces Thymeleaf and Kustomize concepts that distract from zero-scale + Leyden, adds classpath overhead, and requires building/importing two images into `k3d`.

### Approach C: Spring Boot Buildpacks + Local Helm Umbrella Chart
- **What it is:** Paketo Buildpacks (`BP_JVM_AOTCACHE_ENABLED=true`) and a single Helm chart wrapping Postgres, app, Istio, and KEDA resources.
- **Trade-offs:** Fewer CLI steps, but hides both the Project Leyden CLI mechanics and the raw Kubernetes/Istio/KEDA YAML that readers came to learn.

**Decision:** **Approach A** (refined to use **Bootstrap 5** so the single-page HTML/JS UI stays clean and simple without hand-rolling complex CSS).

---

## 5. Decided Architecture & Design

### 5.1 Request Flow & Scale-to-Zero Architecture

```text
Browser / curl (localhost:8080)
  │
  ▼
k3d LoadBalancer ──► Istio Ingress Gateway (istio-system)
                        │  Gateway + VirtualService (Host: task-org.local / *)
                        ▼
                     KEDA HTTP Add-on Interceptor Proxy (keda namespace)
                        │  • If replicas == 0: buffers HTTP request, notifies
                        │    External Scaler -> KEDA ScaledObject scales 0 -> 1
                        │  • Waits for pod Readiness probe -> forwards request
                        ▼
                     task-org-webapp Service & Deployment (task-org namespace)
                        │  • Spring Boot 4.1.2 / Java 25 + Project Leyden AOT Cache
                        │  • Istio sidecar injected (or mesh-participating)
                        │  • Scales 0 <-> N via KEDA ScaledObject
                        ▼
                     PostgreSQL StatefulSet (task-org namespace, replicas: 1)
                        └── PersistentVolumeClaim
```

### 5.2 Demo Application (`task-org-webapp`)
- **Domain:** Organize tasks into projects.
  - `projects` table: `id`, `name`, `description`, `created_at`
  - `tasks` table: `id`, `project_id` (FK -> `projects.id` ON DELETE CASCADE), `title`, `completed` (boolean), `created_at`
  - Initialized via `schema.sql` (`CREATE TABLE IF NOT EXISTS ...`) plus optional seed data (`data.sql` or idempotent init) so the UI immediately shows sample projects/tasks on first load.
- **Persistence:** Spring Data JDBC (`CrudRepository` / `ListCrudRepository`) with PostgreSQL.
- **REST API:**
  - `GET /api/projects`, `POST /api/projects`, `DELETE /api/projects/{id}`
  - `GET /api/projects/{id}/tasks`, `POST /api/projects/{id}/tasks`
  - `PATCH /api/tasks/{id}` (toggle completed / update title), `DELETE /api/tasks/{id}`
- **UI:** Served from `src/main/resources/static/index.html` using **Bootstrap 5** (CDN) + a small `app.js` calling the REST API via `fetch()`. Features: sidebar/list of projects (create/select/delete) and main panel of tasks for the selected project (add, toggle complete, delete).
- **Health & Readiness:** Add `spring-boot-starter-actuator` with `/actuator/health/readiness` and `/actuator/health/liveness` enabled so Kubernetes readiness probes accurately gate traffic from the KEDA HTTP Interceptor.

### 5.3 Container Image & Project Leyden AOT Cache
- Multi-stage `Dockerfile` in `task-org-webapp/Dockerfile`:
  1. **Build stage:** Builds the Spring Boot fat JAR via Maven (`./mvnw package -DskipTests`) and extracts it using `java -Djarmode=tools -jar target/*.jar extract --destination application`.
  2. **Runtime + AOT training stage (`eclipse-temurin:25-jre`):** Copies the extracted `application/` directory and runs the Project Leyden training pass:
     ```dockerfile
     RUN java -XX:AOTCacheOutput=app.aot \
              -Dspring.context.exit=onRefresh \
              -Dspring.profiles.active=aot-training \
              -jar task-org-webapp.jar
     ```
     The `aot-training` profile prevents failure when PostgreSQL is absent during `docker build` (while still loading Spring WebMVC, Spring Data JDBC, Jackson, Actuator, and Tomcat classes into `app.aot`).
  3. **Entrypoint:** `ENTRYPOINT ["java", "-jar", "task-org-webapp.jar"]`.
     - **Baseline JVM run:** `JAVA_TOOL_OPTIONS` unset.
     - **Leyden AOT run:** `JAVA_TOOL_OPTIONS=-XX:AOTCache=app.aot` in the Kubernetes `Deployment` (toggled via a one-line `kubectl set env` or manifest edit for benchmarking).
- Image is imported directly into the local `k3d` cluster via `k3d image import` (no external container registry required).

### 5.4 Kubernetes, Istio, and KEDA Layout (`k8s/`)
```text
k8s/
├── 00-namespace.yaml          # task-org namespace (with istio-injection=enabled)
├── 01-postgres/
│   ├── secret.yaml            # DB credentials
│   ├── service.yaml           # Headless/ClusterIP service for Postgres
│   └── statefulset.yaml       # PostgreSQL StatefulSet (1 replica + volumeClaimTemplates)
├── 02-app/
│   ├── deployment.yaml        # task-org-webapp Deployment (readiness/liveness probes, JAVA_TOOL_OPTIONS)
│   └── service.yaml           # ClusterIP service on port 8080
├── 03-keda/
│   ├── interceptor-route.yaml # http.keda.sh/v1beta1 InterceptorRoute -> task-org-webapp:8080
│   └── scaled-object.yaml     # keda.sh/v1alpha1 ScaledObject (minReplicaCount: 0, external-push)
└── 04-istio/
    ├── gateway.yaml           # Istio Gateway on port 80
    └── virtual-service.yaml   # Routes incoming HTTP -> keda-add-ons-http-interceptor-proxy.keda.svc.cluster.local:8080
```
- Helper scripts (e.g., `scripts/setup-cluster.sh` and `scripts/benchmark-cold-start.sh`) automate repeatable local verification while keeping every underlying command transparent for the article.

### 5.5 Article Outline (`zero-scale.article.md`)
1. **Overview & Motivation:** What zero-scale architecture is, when it makes sense, and why HTTP scale-to-zero is harder than queue-based scaling.
2. **Why Project Leyden AOT Cache (vs. GraalVM Native Image):** The cold-start problem in Java; why GraalVM native images complicate APM instrumentation (e.g., Dynatrace); how Java 25 Project Leyden AOT Cache keeps HotSpot + Java agents intact while slashing startup time.
3. **Architecture Overview:** Explaining the roles of Istio Service Mesh, KEDA Core, KEDA HTTP Add-on (`InterceptorRoute` + `ScaledObject`), and PostgreSQL (`StatefulSet`)—with a clear diagram.
4. **Prerequisites & Local Cluster Setup:** Homebrew / `mise` setup for `kubectl`, `k3d`, `helm`, `istioctl`, Java 25; creating the `k3d` cluster (Traefik disabled); installing Istio, KEDA Core, and KEDA HTTP Add-on.
5. **The Demo Application (`task-org-webapp`):** Brief tour of the Spring Boot 4.1 + Spring Data JDBC + Bootstrap 5 app and its Leyden-enabled `Dockerfile`.
6. **Deploying to Kubernetes:** Applying Postgres (`StatefulSet`), `task-org-webapp`, KEDA `InterceptorRoute` + `ScaledObject`, and Istio `Gateway` + `VirtualService`.
7. **Testing Scale-to-Zero & Benchmarking Cold Starts:** Watching replicas drop to `0`, triggering a cold start via browser and `curl`, and comparing startup + time-to-first-byte **without** vs. **with** `-XX:AOTCache=app.aot` (with real measured numbers from our `k3d` run).
8. **Summary & Caveats:** Practical considerations (cooldown period tuning, readiness probe frequency, Istio sidecar startup overhead during cold start, DB connection pooling on scale-up).

---

## 6. What's Left to the Builder

- Exact Maven dependency versions and `schema.sql` / seed data details.
- Exact Bootstrap 5 layout and JS structure inside `src/main/resources/static/` (keeping it concise and readable).
- Exact `aot-training` Spring profile properties needed for Spring Boot 4.1.2 + Spring Data JDBC so `java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh` exits cleanly with code `0` and produces a valid `app.aot` that loads cleanly at runtime against PostgreSQL.
- Exact `k3d` port mapping (e.g., `8080:80@loadbalancer`), Istio profile (`demo` vs. `minimal` + ingressgateway), and KEDA `cooldownPeriod` / `scaledownPeriod` values tuned for a snappy local demo (e.g., 30–60s).
- Exact wording and formatting of `zero-scale.article.md` (preserving the user's Homebrew/`mise` preference from the existing draft).
- Unit/integration tests for `task-org-webapp` and end-to-end verification in a live `k3d` cluster before recording benchmark numbers in the article.
