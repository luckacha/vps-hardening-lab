FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv python3 openssh-server sudo ca-certificates && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
