# Stage 0: pull the runtime base for the *target* platform first.
# why: a stage pinned to $BUILDPLATFORM can make buildah reuse the other
# architecture's cached layers for the final stage (buildah issue 4742)
FROM mcr.microsoft.com/dotnet/runtime:10.0.13-alpine3.24@sha256:6a97a629f6c44e7263b41175e79cb9aeb1df631d3714e74e80a4ddd016258646 AS target

# Stage 1: Build (runs natively; cross-publishes for the target arch)
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0.402-alpine3.24@sha256:496914451b05ac5a24592024362ec370c3a2d3c3fe817f864e4aa55c4c194a56 AS build
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
ENV DB_NAME=postgres
ENV REDIS_HOST=redis

# app, the unprivileged user the .NET image ships
USER 1654

# Define the entry point
ENTRYPOINT ["dotnet", "Worker.dll"]
