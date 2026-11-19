# Zero-Scale Java/Spring Boot Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `task-org-webapp` Spring Boot 4.1 / Java 25 demo application with Project Leyden AOT Cache, deploy it on a local `k3d` cluster behind Istio Service Mesh and KEDA + KEDA HTTP Add-on (`InterceptorRoute` + `ScaledObject`) backed by a PostgreSQL `StatefulSet`, benchmark cold starts, and write the complete technical article in `zero-scale.article.md`.

**Architecture:** Incoming HTTP traffic flows `Client -> k3d LoadBalancer -> Istio Ingress Gateway -> VirtualService -> KEDA HTTP Add-on Interceptor -> task-org-webapp -> PostgreSQL StatefulSet`. A single multi-stage `Dockerfile` extracts the Spring Boot JAR and generates a Java 25 Project Leyden `app.aot` cache during image build; toggling `JAVA_TOOL_OPTIONS=-XX:AOTCache=app.aot` on the Deployment lets readers benchmark baseline JVM vs. Leyden AOT cold starts without rebuilding images.

**Tech Stack:** Java 25 (OpenJDK / Temurin), Spring Boot 4.1.2 (WebMVC, Spring Data JDBC, Actuator), PostgreSQL 17, Bootstrap 5 (CDN) + vanilla JS, Docker, `k3d`, Istio, KEDA Core + KEDA HTTP Add-on (`http.keda.sh/v1beta1` `InterceptorRoute` + `keda.sh/v1alpha1` `ScaledObject`), Homebrew / `mise`.

**Spec:** [docs/superpowers/specs/2026-11-18-zero-scale-article-design.md](file:///home/sbaramov/Development/personal/article-zero-scale/docs/superpowers/specs/2026-11-18-zero-scale-article-design.md)

## Global Constraints

- Use the existing Spring Boot `4.1.2` / Java `25` Maven project in `task-org-webapp/` (`package taskorg`).
- No GraalVM native image build in this repository (discussed conceptually in the article to frame the APM/Dynatrace trade-off).
- PostgreSQL runs as a `StatefulSet` at `1` replica with persistent storage; only `task-org-webapp` scales to/from `0`.
- No Node.js/npm/Vite frontend build pipeline; UI is static HTML + Bootstrap 5 (CDN) + vanilla JS in `src/main/resources/static/`.
- Use plain, readable Kubernetes YAML in `k8s/` (no Helm umbrella chart or Kustomize overlays) and an explicit `Dockerfile` showing `-XX:AOTCacheOutput` / `-XX:AOTCache`.
- Use KEDA HTTP Add-on v0.14+ resources (`InterceptorRoute` + standard `ScaledObject` with `external-push` trigger), not the deprecated `HTTPScaledObject`.
- Disable Istio sidecar injection on the `keda` namespace (`istio-injection=disabled`) and disable Traefik in `k3d` (`--disable=traefik@server:0`).
- Every command, manifest, and benchmark number in `zero-scale.article.md` must match the verified files and live `k3d` measurements in this repository.

## Review Focus

1. **Blank/whitespace names or titles:** `POST /api/projects`, `POST /api/projects/{id}/tasks`, and `PATCH /api/tasks/{id}` with blank or whitespace-only strings must return `400 Bad Request` rather than persisting empty rows (pinned in Task 2).
2. **Non-existent project or task IDs:** Fetching/creating tasks on a missing project or updating/deleting a missing project/task must return `404 Not Found` rather than `500` or silent success (pinned in Task 2).
3. **XSS via project/task names in the UI:** Rendering user-entered HTML/script characters in `app.js` must use safe DOM APIs (`textContent`) instead of raw `innerHTML` interpolation (pinned in Task 3).
4. **Leyden AOT training without live Postgres:** `docker build` runs `-XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh` with no database; the `aot-training` profile must exit `0` and produce an `app.aot` that loads cleanly at runtime against real PostgreSQL (pinned in Tasks 1 & 4).
5. **Cold-start readiness gating:** A request hitting Istio Gateway while `task-org-webapp` is at `0` replicas must be held by the KEDA Interceptor until `/actuator/health/readiness` passes and return `200 OK`, never `502`/`503` (pinned in Tasks 3 & 5).

---

## File Structure

```text
article-zero-scale/
├── zero-scale.article.md                      # Modify: complete technical article
├── task-org-webapp/
│   ├── pom.xml                                # Modify: add spring-boot-starter-actuator + h2 (test)
│   ├── Dockerfile                             # Create: multi-stage Java 25 + Leyden AOT build
│   ├── .dockerignore                          # Create: exclude target/, .git/, IDE files
│   └── src/
│       ├── main/
│       │   ├── java/taskorg/
│       │   │   ├── TaskOrgWebappApplication.java      # Existing entry point
│       │   │   ├── project/
│       │   │   │   ├── Project.java                   # Create: Spring Data JDBC entity record
│       │   │   │   ├── ProjectRepository.java         # Create: ListCrudRepository
│       │   │   │   └── ProjectController.java         # Create: /api/projects REST endpoints
│       │   │   ├── task/
│       │   │   │   ├── Task.java                      # Create: Spring Data JDBC entity record
│       │   │   │   ├── TaskRepository.java            # Create: ListCrudRepository + findByProjectId
│       │   │   │   └── TaskController.java            # Create: /api/projects/{id}/tasks & /api/tasks/{id}
│       │   │   └── ApiExceptionHandler.java           # Create: 400/404 ProblemDetail/JSON handler
│       │   └── resources/
│       │       ├── application.yaml                   # Modify: datasource, sql init, actuator probes
│       │       ├── application-aot-training.yaml      # Create: DB-free profile for Leyden training run
│       │       ├── schema.sql                         # Create: idempotent projects & tasks DDL
│       │       ├── data.sql                           # Create: idempotent sample projects & tasks
│       │       └── static/
│       │           ├── index.html                     # Create: Bootstrap 5 single-page UI
│       │           └── app.js                         # Create: vanilla fetch() client (safe DOM rendering)
│       └── test/
│           ├── java/taskorg/
│           │   ├── TaskOrgWebappApplicationTests.java # Modify: test context load with aot-training profile
│           │   ├── PersistenceTests.java              # Create: @DataJdbcTest CRUD + cascade delete
│           │   └── ApiAndUiTests.java                 # Create: MockMvc REST API, validation, 404, UI & health
│           └── resources/
│               └── application-test.yaml              # Create: H2 in PostgreSQL mode for fast tests
├── k8s/
│   ├── 00-namespace.yaml                      # Create: task-org namespace (istio-injection=enabled)
│   ├── 01-postgres/
│   │   ├── secret.yaml                        # Create: Postgres credentials
│   │   ├── service.yaml                       # Create: ClusterIP service (postgres:5432)
│   │   └── statefulset.yaml                   # Create: Postgres 17 StatefulSet (1 replica + PVC)
│   ├── 02-app/
│   │   ├── deployment.yaml                    # Create: task-org-webapp Deployment + probes + env
│   │   └── service.yaml                       # Create: ClusterIP service (task-org-webapp:8080)
│   ├── 03-keda/
│   │   ├── interceptor-route.yaml             # Create: http.keda.sh/v1beta1 InterceptorRoute
│   │   └── scaled-object.yaml                 # Create: keda.sh/v1alpha1 ScaledObject (minReplicaCount: 0)
│   └── 04-istio/
│       ├── gateway.yaml                       # Create: Istio Gateway on port 80
│       └── virtual-service.yaml               # Create: routes to keda-add-ons-http-interceptor-proxy
└── scripts/
    ├── setup-cluster.sh                       # Create: k3d + Istio + KEDA + build/import + kubectl apply
    └── benchmark-cold-start.sh                # Create: measures baseline JVM vs Leyden AOT cold starts
```

---

### Task 1: Persistence Layer, Configuration & Actuator Health

**Files:**
- Modify: `task-org-webapp/pom.xml`
- Modify: `task-org-webapp/src/main/resources/application.yaml`
- Create: `task-org-webapp/src/main/resources/application-aot-training.yaml`
- Create: `task-org-webapp/src/main/resources/schema.sql`
- Create: `task-org-webapp/src/main/resources/data.sql`
- Create: `task-org-webapp/src/main/java/taskorg/project/Project.java`
- Create: `task-org-webapp/src/main/java/taskorg/project/ProjectRepository.java`
- Create: `task-org-webapp/src/main/java/taskorg/task/Task.java`
- Create: `task-org-webapp/src/main/java/taskorg/task/TaskRepository.java`
- Create: `task-org-webapp/src/test/resources/application-test.yaml`
- Create: `task-org-webapp/src/test/java/taskorg/PersistenceTests.java`
- Modify: `task-org-webapp/src/test/java/taskorg/TaskOrgWebappApplicationTests.java`

**Interfaces:**
- Consumes: Spring Boot 4.1.2 starter scaffold in `task-org-webapp/`.
- Produces:
  - `record Project(@Id Long id, String name, String description, Instant createdAt)` mapped to `@Table("projects")`
  - `interface ProjectRepository extends ListCrudRepository<Project, Long>` with `List<Project> findAllByOrderByIdAsc()`
  - `record Task(@Id Long id, Long projectId, String title, boolean completed, Instant createdAt)` mapped to `@Table("tasks")`
  - `interface TaskRepository extends ListCrudRepository<Task, Long>` with `List<Task> findByProjectIdOrderByIdAsc(Long projectId)`
  - Profiles: default (PostgreSQL via `DB_URL`/`DB_USERNAME`/`DB_PASSWORD` env vars with sensible local defaults), `aot-training` (DB-free startup for Leyden training), `test` (H2 in PostgreSQL mode).

- [ ] **Step 1: Add `spring-boot-starter-actuator` and test-scoped `com.h2database:h2` to `task-org-webapp/pom.xml`**

Add `org.springframework.boot:spring-boot-starter-actuator` (compile scope) and `com.h2database:h2` (`<scope>test</scope>`).

- [ ] **Step 2: Write failing persistence and AOT-training context tests**

Create `task-org-webapp/src/test/resources/application-test.yaml` configuring H2 in PostgreSQL mode (`jdbc:h2:mem:taskorg;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DEFAULT_NULL_ORDERING=HIGH`) with `spring.sql.init.mode: always`.

Create `task-org-webapp/src/test/java/taskorg/PersistenceTests.java` (`@DataJdbcTest`, `@ActiveProfiles("test")`):
```java
@Test
void savesAndListsProjectsAndTasksAndCascadesDelete() {
    Project saved = projectRepository.save(new Project(null, "Alpha", "First project", Instant.now()));
    assertThat(saved.id()).isNotNull();

    Task t1 = taskRepository.save(new Task(null, saved.id(), "Task 1", false, Instant.now()));
    Task t2 = taskRepository.save(new Task(null, saved.id(), "Task 2", true, Instant.now()));
    assertThat(taskRepository.findByProjectIdOrderByIdAsc(saved.id()))
            .extracting(Task::title)
            .containsExactly("Task 1", "Task 2");

    projectRepository.deleteById(saved.id());
    assertThat(taskRepository.findByProjectIdOrderByIdAsc(saved.id())).isEmpty();
}
```

Update `task-org-webapp/src/test/java/taskorg/TaskOrgWebappApplicationTests.java` to run with `@ActiveProfiles("aot-training")` so `contextLoads()` proves the app boots cleanly without a live database.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd task-org-webapp && ./mvnw test`
Expected: FAIL (compilation error — `Project`, `Task`, repositories do not exist yet).

- [ ] **Step 4: Implement schema, seed data, profiles, entities, and repositories**

- Create `schema.sql`: `CREATE TABLE IF NOT EXISTS projects (id BIGSERIAL PRIMARY KEY, name VARCHAR(200) NOT NULL, description TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP);` and `CREATE TABLE IF NOT EXISTS tasks (id BIGSERIAL PRIMARY KEY, project_id BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, title VARCHAR(300) NOT NULL, completed BOOLEAN NOT NULL DEFAULT FALSE, created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP);`.
- Create `data.sql`: Idempotent seed inserts (`INSERT INTO projects ... WHERE NOT EXISTS (SELECT 1 FROM projects)`) inserting 2 sample projects and 3 sample tasks so the UI is populated on first load without duplicating rows on pod restarts.
- Update `application.yaml`: Configure `spring.datasource.{url,username,password}` using `${DB_URL:jdbc:postgresql://localhost:5432/taskorg}`, `${DB_USERNAME:taskorg}`, `${DB_PASSWORD:taskorg}`, `spring.sql.init.mode: always`, `management.endpoint.health.probes.enabled: true`, `management.health.livenessstate.enabled: true`, `management.health.readinessstate.enabled: true`, `management.endpoints.web.exposure.include: health`.
- Create `application-aot-training.yaml`: Set `spring.sql.init.mode: never`, `spring.datasource.hikari.initialization-fail-timeout: -1`, `spring.datasource.url: jdbc:postgresql://127.0.0.1:5432/taskorg`, `spring.datasource.username: training`, `spring.datasource.password: training`, and `management.health.db.enabled: false` so HikariCP creates the pool lazily without connecting during `-Dspring.context.exit=onRefresh`.
- Create `Project.java`, `ProjectRepository.java`, `Task.java`, `TaskRepository.java` matching the Interfaces block.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd task-org-webapp && ./mvnw test`
Expected: PASS (`PersistenceTests` and `TaskOrgWebappApplicationTests` green).

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/ task-org-webapp/
git commit -m "feat: add persistence layer, actuator probes, and aot-training profile"
```

---

### Task 2: REST API Controllers & Input Validation

**Files:**
- Create: `task-org-webapp/src/main/java/taskorg/project/ProjectController.java`
- Create: `task-org-webapp/src/main/java/taskorg/task/TaskController.java`
- Create: `task-org-webapp/src/main/java/taskorg/ApiExceptionHandler.java`
- Create: `task-org-webapp/src/test/java/taskorg/ApiAndUiTests.java`

**Interfaces:**
- Consumes: `Project`, `ProjectRepository`, `Task`, `TaskRepository` from Task 1.
- Produces:
  - `GET /api/projects` -> `200 OK`, JSON array of `Project`
  - `POST /api/projects` (body `{ "name": "...", "description": "..." }`) -> `201 Created`, `Project`; `400 Bad Request` if `name` is null/blank
  - `DELETE /api/projects/{id}` -> `204 No Content`; `404 Not Found` if project does not exist
  - `GET /api/projects/{projectId}/tasks` -> `200 OK`, JSON array of `Task`; `404 Not Found` if project does not exist
  - `POST /api/projects/{projectId}/tasks` (body `{ "title": "..." }`) -> `201 Created`, `Task`; `400 Bad Request` if `title` is null/blank; `404 Not Found` if project does not exist
  - `PATCH /api/tasks/{id}` (body `{ "title": "...", "completed": true }`, fields optional) -> `200 OK`, updated `Task`; `400 Bad Request` if `title` is provided as blank; `404 Not Found` if task does not exist
  - `DELETE /api/tasks/{id}` -> `204 No Content`; `404 Not Found` if task does not exist

- [ ] **Step 1: Write failing API tests (including Review Focus items #1 and #2)**

Create `task-org-webapp/src/test/java/taskorg/ApiAndUiTests.java` (`@SpringBootTest`, `@AutoConfigureMockMvc`, `@ActiveProfiles("test")`) with tests:
- `projectAndTaskCrudLifecycle()`: creates project (`201`), lists projects (`200`), creates task (`201`), toggles `completed` via `PATCH /api/tasks/{id}` (`200`), deletes task (`204`), deletes project (`204`).
- `rejectsBlankProjectNameAndTaskTitle()`: `POST /api/projects` with `{"name":"   "}` -> `400`; `POST /api/projects/{id}/tasks` with `{"title":""}` -> `400`; `PATCH /api/tasks/{id}` with `{"title":"  "}` -> `400`.
- `returns404ForMissingProjectOrTask()`: `GET /api/projects/99999/tasks` -> `404`; `POST /api/projects/99999/tasks` -> `404`; `DELETE /api/projects/99999` -> `404`; `PATCH /api/tasks/99999` -> `404`; `DELETE /api/tasks/99999` -> `404`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd task-org-webapp && ./mvnw test -Dtest=ApiAndUiTests`
Expected: FAIL (`404` on `/api/projects` because controllers do not exist).

- [ ] **Step 3: Implement `ProjectController`, `TaskController`, and `ApiExceptionHandler`**

Implement the endpoints and request records per the Interfaces block. Throw `ResponseStatusException(HttpStatus.BAD_REQUEST, ...)` for blank input and `ResponseStatusException(HttpStatus.NOT_FOUND, ...)` for missing IDs, with `ApiExceptionHandler` returning clean JSON `{ "error": "..." }` responses.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd task-org-webapp && ./mvnw test`
Expected: PASS (all tests green).

- [ ] **Step 5: Commit**

```bash
git add task-org-webapp/src/
git commit -m "feat: add projects and tasks REST API with validation"
```

---

### Task 3: Bootstrap 5 Single-Page UI & Health Probe Verification

**Files:**
- Create: `task-org-webapp/src/main/resources/static/index.html`
- Create: `task-org-webapp/src/main/resources/static/app.js`
- Modify: `task-org-webapp/src/test/java/taskorg/ApiAndUiTests.java`

**Interfaces:**
- Consumes: REST API endpoints from Task 2 and Actuator probes from Task 1.
- Produces: Static UI at `/` and `/app.js`, verified alongside `/actuator/health/readiness` and `/actuator/health/liveness`.

- [ ] **Step 1: Add failing UI and Actuator probe tests to `ApiAndUiTests.java`**

Add tests to `ApiAndUiTests.java`:
- `servesBootstrapUiAndScript()`: `GET /` returns `200`, `text/html`, body contains `bootstrap` and `app.js`; `GET /app.js` returns `200`, body contains `/api/projects` and does NOT contain `.innerHTML =` (pins Review Focus #3: safe DOM rendering via `textContent`).
- `exposesReadinessAndLivenessProbes()`: `GET /actuator/health/readiness` and `GET /actuator/health/liveness` both return `200` with `$.status == "UP"` (pins Review Focus #5).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd task-org-webapp && ./mvnw test -Dtest=ApiAndUiTests`
Expected: FAIL (`GET /` returns `404`).

- [ ] **Step 3: Implement `index.html` and `app.js`**

- `index.html`: Clean Bootstrap 5.3 (CDN) layout with a navbar ("Task Organizer"), left column for Projects (list + inline create form + delete button), right column for Tasks of the selected project (add task input + checklist items with completion toggle and delete button), and a subtle alert container for errors.
- `app.js`: Concise vanilla JS calling the Task 2 REST API via `fetch()`. Build all dynamic DOM nodes with `document.createElement` + `textContent` (never interpolating user text into `innerHTML`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd task-org-webapp && ./mvnw test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add task-org-webapp/src/
git commit -m "feat: add Bootstrap 5 single-page UI and probe tests"
```

---

### Task 4: Multi-Stage Dockerfile & Project Leyden AOT Cache

**Files:**
- Create: `task-org-webapp/.dockerignore`
- Create: `task-org-webapp/Dockerfile`

**Interfaces:**
- Consumes: `task-org-webapp/` Maven project and `aot-training` profile from Tasks 1–3.
- Produces: Docker image `task-org-webapp:latest` containing extracted Spring Boot layout + `/app/app.aot` generated via Java 25 Project Leyden, with `ENTRYPOINT ["java", "-jar", "task-org-webapp.jar"]` so `JAVA_TOOL_OPTIONS=-XX:AOTCache=app.aot` toggles AOT caching at runtime.

- [ ] **Step 1: Create `.dockerignore` and `Dockerfile`**

- `.dockerignore`: ignore `target/`, `.git/`, `*.iml`, `.idea/`.
- `Dockerfile`:
  - Stage 1 (`builder`, `eclipse-temurin:25-jdk`): copy `pom.xml`, `.mvn/`, `mvnw`, run `./mvnw dependency:go-offline -B`, copy `src/`, run `./mvnw package -DskipTests -B`, then extract JAR with `java -Djarmode=tools -jar target/task-org-webapp-0.0.1-SNAPSHOT.jar extract --destination /extracted` (rename inner JAR to `task-org-webapp.jar` or keep consistent name).
  - Stage 2 (`runtime`, `eclipse-temurin:25-jre`): `WORKDIR /app`, copy `/extracted/` from `builder`, run Leyden training pass:
    ```dockerfile
    RUN java -XX:AOTCacheOutput=app.aot \
             -Dspring.context.exit=onRefresh \
             -Dspring.profiles.active=aot-training \
             -jar task-org-webapp-0.0.1-SNAPSHOT.jar
    ```
    Expose `8080`, `ENTRYPOINT ["java", "-jar", "task-org-webapp-0.0.1-SNAPSHOT.jar"]`.

- [ ] **Step 2: Build image and verify `app.aot` generation (pins Review Focus #4)**

Run:
```bash
docker build -t task-org-webapp:latest task-org-webapp
docker run --rm --entrypoint ls task-org-webapp:latest -lh /app/app.aot
```
Expected: Build exits `0`; `/app/app.aot` exists and is non-empty (typically tens of MB).

- [ ] **Step 3: Verify container startup without vs. with `-XX:AOTCache=app.aot`**

Run:
```bash
docker run --rm -e SPRING_PROFILES_ACTIVE=aot-training -e SPRING_CONTEXT_EXIT=onRefresh task-org-webapp:latest
docker run --rm -e JAVA_TOOL_OPTIONS=-XX:AOTCache=app.aot -e SPRING_PROFILES_ACTIVE=aot-training -e SPRING_CONTEXT_EXIT=onRefresh task-org-webapp:latest
```
Expected: Both exit `0` with `Started TaskOrgWebappApplication in X.XXX seconds` (with AOT cache measurably faster and no AOT cache incompatibility warnings).

- [ ] **Step 4: Commit**

```bash
git add task-org-webapp/.dockerignore task-org-webapp/Dockerfile
git commit -m "feat: add multi-stage Dockerfile with Java 25 Project Leyden AOT cache"
```

---

### Task 5: Kubernetes, PostgreSQL StatefulSet, KEDA HTTP Add-on & Istio Stack + Live `k3d` Benchmark

**Files:**
- Create: `k8s/00-namespace.yaml`
- Create: `k8s/01-postgres/secret.yaml`
- Create: `k8s/01-postgres/service.yaml`
- Create: `k8s/01-postgres/statefulset.yaml`
- Create: `k8s/02-app/deployment.yaml`
- Create: `k8s/02-app/service.yaml`
- Create: `k8s/03-keda/interceptor-route.yaml`
- Create: `k8s/03-keda/scaled-object.yaml`
- Create: `k8s/04-istio/gateway.yaml`
- Create: `k8s/04-istio/virtual-service.yaml`
- Create: `scripts/setup-cluster.sh`
- Create: `scripts/benchmark-cold-start.sh`

**Interfaces:**
- Consumes: `task-org-webapp:latest` image from Task 4.
- Produces: Reproducible local `k3d` cluster (`zero-scale`) exposing `http://localhost:8080`, all `k8s/` manifests, and recorded real cold-start measurements (baseline JVM vs. Leyden AOT) for Task 6.

- [ ] **Step 1: Ensure `helm` and `istioctl` are available locally**

Check `command -v helm istioctl`; install missing tools via `mise` or `brew` (matching the article's prerequisites).

- [ ] **Step 2: Create all Kubernetes, KEDA, and Istio YAML manifests under `k8s/`**

- `k8s/00-namespace.yaml`: Namespace `task-org` with label `istio-injection: enabled`.
- `k8s/01-postgres/`: `Secret` (`postgres-secret`), `Service` (`postgres`, port `5432`), `StatefulSet` (`postgres:17-alpine`, `replicas: 1`, `volumeClaimTemplates` `1Gi`, `pg_isready` readiness probe).
- `k8s/02-app/`: `Service` (`task-org-webapp`, port `8080`), `Deployment` (`task-org-webapp:latest`, `imagePullPolicy: IfNotPresent`, `DB_URL=jdbc:postgresql://postgres:5432/taskorg`, credentials from `postgres-secret`, `JAVA_TOOL_OPTIONS=-XX:AOTCache=app.aot`, fast HTTP readiness probe on `/actuator/health/readiness` with `periodSeconds: 1`, `initialDelaySeconds: 0` so KEDA Interceptor forwards immediately once Spring Boot is ready, and liveness probe on `/actuator/health/liveness`).
- `k8s/03-keda/`:
  - `interceptor-route.yaml` (`http.keda.sh/v1beta1`, `InterceptorRoute` named `task-org-webapp` in namespace `task-org`, targeting service `task-org-webapp` port `8080`, host `*` or `localhost`, `paths: [{value: /}]`, `scalingMetric.requestRate.targetValue: 5`).
  - `scaled-object.yaml` (`keda.sh/v1alpha1`, `ScaledObject` named `task-org-webapp` in namespace `task-org`, `scaleTargetRef.name: task-org-webapp`, `minReplicaCount: 0`, `maxReplicaCount: 5`, `cooldownPeriod: 30`, `pollingInterval: 5`, `triggers` with `type: external-push`, `scalerAddress: keda-add-ons-http-external-scaler.keda:9090`, `interceptorRoute: task-org-webapp`).
- `k8s/04-istio/`:
  - `gateway.yaml`: Istio `Gateway` (`task-org-gateway`) on `istio: ingressgateway`, port `80`, hosts `["*"]`.
  - `virtual-service.yaml`: Istio `VirtualService` (`task-org-vs`) bound to `task-org-gateway`, routing all HTTP traffic to `keda-add-ons-http-interceptor-proxy.keda.svc.cluster.local` on port `8080` (with `X-KEDA-HTTP-Cold-Start-Timeout` / host header preserved as needed).

- [ ] **Step 3: Create `scripts/setup-cluster.sh` and `scripts/benchmark-cold-start.sh`**

- `scripts/setup-cluster.sh`: Creates `k3d cluster create zero-scale -p "8080:80@loadbalancer" --k3s-arg "--disable=traefik@server:0"`, installs Istio (`istioctl install --set profile=default -y`), creates `keda` namespace labeled `istio-injection=disabled`, installs `kedacore/keda` and `kedacore/keda-add-ons-http` via Helm, builds & imports `task-org-webapp:latest` into `k3d`, and applies `k8s/` in order.
- `scripts/benchmark-cold-start.sh`: Runs a repeatable benchmark loop: (1) sets `JAVA_TOOL_OPTIONS=""` (baseline JVM), waits for replicas to reach `0`, times `curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://localhost:8080/api/projects` and captures the pod's `Started TaskOrgWebappApplication in ...` log line; (2) sets `JAVA_TOOL_OPTIONS="-XX:AOTCache=app.aot"` (Leyden AOT), waits for replicas to reach `0`, and repeats the timed `curl` + startup log capture.

- [ ] **Step 4: Run `scripts/setup-cluster.sh` and verify live end-to-end scale-to-zero (pins Review Focus #5)**

Run:
```bash
./scripts/setup-cluster.sh
./scripts/benchmark-cold-start.sh
```
Expected:
- Postgres StatefulSet `postgres-0` is `1/1 Running`.
- `task-org-webapp` scales down to `0` after ~30s idle.
- Cold-start `curl http://localhost:8080/api/projects` returns HTTP `200` (not `502`/`503`) with valid JSON projects.
- Both baseline JVM and Leyden AOT cold-start timings (app startup + total HTTP TTFB) are captured cleanly, with Leyden AOT measurably faster.

- [ ] **Step 5: Commit**

```bash
git add k8s/ scripts/
git commit -m "feat: add k8s, postgres statefulset, KEDA HTTP add-on, Istio manifests and scripts"
```

---

### Task 6: Write the Complete Article (`zero-scale.article.md`)

**Files:**
- Modify: `zero-scale.article.md`

**Interfaces:**
- Consumes: Verified code, `Dockerfile`, `k8s/` manifests, scripts, and actual benchmark numbers from Tasks 1–5.
- Produces: Publication-ready `zero-scale.article.md`.

- [ ] **Step 1: Write `zero-scale.article.md` covering all 8 sections from the spec**

Preserve the Homebrew / `mise` setup style from the existing draft and include:
1. Overview & Motivation (why HTTP scale-to-zero differs from queue-based scaling).
2. Why Project Leyden AOT Cache over GraalVM Native Image (including the Dynatrace / APM Java agent instrumentation rationale).
3. Architecture Overview with a Mermaid flowchart (`Client -> Istio Ingress Gateway -> VirtualService -> KEDA HTTP Interceptor -> task-org-webapp -> Postgres StatefulSet`).
4. Prerequisites & Local `k3d` Cluster Setup (Homebrew/`mise`, `k3d` without Traefik, Istio, KEDA Core + KEDA HTTP Add-on with `istio-injection=disabled`).
5. The Demo Application (`task-org-webapp`: Spring Boot 4.1, Java 25, Spring Data JDBC, Bootstrap 5 UI, and the Leyden `Dockerfile`).
6. Deploying to Kubernetes (walking through Postgres `StatefulSet`, `Deployment` readiness probe tuning, KEDA `InterceptorRoute` + `ScaledObject`, Istio `Gateway` + `VirtualService`).
7. Testing Scale-to-Zero & Benchmarking Cold Starts (exact `kubectl` / `curl` commands and the real measured JVM vs. Leyden AOT table from Task 5).
8. Summary & Production Caveats (cooldown tuning, Istio sidecar startup overhead, readiness probe cadence, DB connection pool sizing).

- [ ] **Step 2: Verify every file path, YAML snippet, and command in `zero-scale.article.md` matches the repo**

Run a quick check that all referenced paths (`k8s/...`, `scripts/...`, `task-org-webapp/...`) exist on disk and match the actual manifest names/APIs.

- [ ] **Step 3: Commit**

```bash
git add zero-scale.article.md
git commit -m "docs: write complete zero-scale Java/Spring Boot article with verified benchmarks"
```
