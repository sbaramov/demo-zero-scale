# Stage 1: Build and extract the Spring Boot application
FROM eclipse-temurin:25.0.5.1_2-jdk AS builder
WORKDIR /build

COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN chmod +x mvnw

COPY src src
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw package -DskipTests -B && \
    java -Djarmode=tools -jar target/app.jar extract --destination /extracted

# Stage 2: Runtime image with Java 25 Project Leyden AOT Cache
FROM eclipse-temurin:25.0.5.1_2-jre
WORKDIR /app

RUN groupadd --gid 10001 app && \
    useradd --uid 10001 --gid 10001 --no-create-home --shell /sbin/nologin app && \
    chown 10001:10001 /app

COPY --from=builder --chown=10001:10001 /extracted/ ./

USER 10001:10001

# Project Leyden AOT training run (JEP 514/515): records loaded classes, linking,
# and profiling metadata into app.aot while exiting cleanly on context refresh.
# GC and heap sizing are pinned explicitly to match the 512Mi container runtime
# (MaxRAMPercentage=75 -> 384m) so the archived heap stays compatible across hosts.
RUN java -XX:+UseG1GC \
         -Xmx384m \
         -XX:AOTCacheOutput=app.aot \
         -Dspring.context.exit=onRefresh \
         -Dspring.profiles.active=aot-training \
         -jar app.jar && \
    test -s app.aot

EXPOSE 8080

# Toggle Project Leyden AOT Cache at runtime via:
#   JAVA_TOOL_OPTIONS="-XX:AOTMode=on -XX:AOTCache=app.aot"
ENTRYPOINT ["java", "-XX:+UseG1GC", "-XX:MaxRAMPercentage=75", "-XX:+ExitOnOutOfMemoryError", "-jar", "app.jar"]
