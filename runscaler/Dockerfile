FROM ghcr.io/actions/actions-runner:latest
USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential docker-compose-v2 gh git-lfs npm psmisc rsync shellcheck xz-utils \
  && rm -rf /var/lib/apt/lists/*
RUN npm install -g n && n 24
RUN mkdir -p /home/runner/go/pkg/mod /home/runner/.cache/go-build /home/runner/.cache/ms-playwright /home/runner/.npm /home/runner/_work/_tool \
  && chown -R runner:runner /home/runner/go /home/runner/.cache /home/runner/.npm /home/runner/_work
USER runner
