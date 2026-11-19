# Stage 1: Build and extract the Spring Boot application
FROM eclipse-temurin:25-jdk AS builder
WORKDIR /build

COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN chmod +x mvnw && ./mvnw dependency:go-offline -B

COPY src src
RUN ./mvnw package -DskipTests -B && \
    java -Djarmode=tools -jar target/task-org-webapp-0.0.1-SNAPSHOT.jar extract --destination /extracted

# Stage 2: Runtime image with Java 25 Project Leyden AOT Cache
FROM eclipse-temurin:25-jre
WORKDIR /app

COPY --from=builder /extracted/ ./

# Project Leyden AOT training run (JEP 514/515): records loaded classes, linking,
# and profiling metadata into app.aot while exiting cleanly on context refresh.
RUN java -XX:AOTCacheOutput=app.aot \
         -Dspring.context.exit=onRefresh \
         -Dspring.profiles.active=aot-training \
         -jar task-org-webapp-0.0.1-SNAPSHOT.jar

EXPOSE 8080

# Toggle Project Leyden AOT Cache at runtime via JAVA_TOOL_OPTIONS=-XX:AOTCache=app.aot
ENTRYPOINT ["java", "-jar", "task-org-webapp-0.0.1-SNAPSHOT.jar"]
