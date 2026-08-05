FROM eclipse-temurin:25-jdk AS build
WORKDIR /workspace

COPY services/password-manager/backend /workspace
RUN chmod +x mvnw && ./mvnw -DskipTests clean package
RUN JAR_PATH="$(ls target/*.jar | grep -Ev 'plain|original' | head -n1)" \
    && cp "$JAR_PATH" /workspace/app.jar

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /workspace/app.jar /app/app.jar

EXPOSE 8091
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
