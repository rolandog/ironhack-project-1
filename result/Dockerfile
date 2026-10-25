# Use a stable, modern Node version
FROM node:24.22.1-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205 AS base

# add curl for healthcheck
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl tini && \
    rm -rf /var/lib/apt/lists/*

# Set the working directory inside the container
WORKDIR /usr/local/app

# Copy package files and install dependencies
COPY package.json package-lock.json .npmrc ./
RUN npm ci --omit=dev --ignore-scripts && \
    npm cache clean --force && \
    mv node_modules /node_modules

# Copy the rest of the app code
COPY . .

# Set default environment variables for both the application and PostgreSQL connection
ARG PORT
ARG PG_HOST
ARG PG_PORT
ARG PG_USER
ARG PG_DATABASE

ENV PORT=${PORT:-80} \
    PG_HOST=${PG_HOST:-db} \
    PG_PORT=${PG_PORT:-5432} \
    PG_USER=${PG_USER:-postgres} \
    PG_DATABASE=${PG_DATABASE:-postgres}

# Expose the app's port (defaults to 80 if not overridden)
EXPOSE $PORT

# Run the app
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]

# local development only: podman build --target=dev
FROM base AS dev
RUN npm install -g nodemon --ignore-scripts
# node, the unprivileged user the Node image ships (UID 1000)
USER 1000
CMD ["nodemon", "server.js"]

# default target: no extra tooling
FROM base AS prod
# node, the unprivileged user the Node image ships (UID 1000)
USER 1000
