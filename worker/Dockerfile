# Stage 0: pull the runtime base for the *target* platform first.
# why: a stage pinned to $BUILDPLATFORM can make buildah reuse the other
# architecture's cached layers for the final stage (buildah issue 4742)
FROM mcr.microsoft.com/dotnet/runtime:8.0 AS target

# Stage 1: Build (runs natively; cross-publishes for the target arch)
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:8.0 AS build
ARG TARGETARCH
WORKDIR /src

# Copy the project file and restore dependencies for the target arch
COPY Worker.csproj .
RUN dotnet restore -a $TARGETARCH

# Copy the rest of the source code and build
COPY . .
RUN dotnet publish -a $TARGETARCH --no-restore -c Release -o /app/publish

# Stage 2: Runtime (resolved for the target platform)
FROM target AS runtime
WORKDIR /app

# Copy the published output from the build stage
COPY --from=build /app/publish ./

# Set environment variables (can be overridden at runtime)
ENV DB_HOST=db
ENV DB_USERNAME=postgres
ENV DB_PASSWORD=postgres
ENV DB_NAME=postgres
ENV REDIS_HOST=redis

# Define the entry point
ENTRYPOINT ["dotnet", "Worker.dll"]
