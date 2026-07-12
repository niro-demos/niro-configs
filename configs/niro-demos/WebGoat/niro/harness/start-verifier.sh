#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
run="$here/run"
container="niro-webgoat-verifier"
image="niro-webgoat:working-tree"
bridge_ip="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"

mkdir -p "$run/verifier-home"
if docker ps --format '{{.Names}}' | grep -qx "$container"; then
  curl --fail --silent http://127.0.0.1:18080/WebGoat/actuator/health >/dev/null
  curl --fail --silent -L http://127.0.0.1:19090/WebWolf/ >/dev/null
  exit 0
fi

docker rm -f "$container" >/dev/null 2>&1 || true
docker run -d --name "$container" \
  --no-healthcheck \
  -p 127.0.0.1:18080:8080 \
  -p "$bridge_ip:18080:8080" \
  -p 127.0.0.1:19090:9090 \
  -p "$bridge_ip:19090:9090" \
  -v "$run/verifier-home:/state" \
  --entrypoint java \
  "$image" \
  -Duser.home=/state -Dfile.encoding=UTF-8 \
  --add-opens java.base/java.lang=ALL-UNNAMED \
  --add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.lang.reflect=ALL-UNNAMED \
  --add-opens java.base/java.text=ALL-UNNAMED \
  --add-opens java.desktop/java.beans=ALL-UNNAMED \
  --add-opens java.desktop/java.awt.font=ALL-UNNAMED \
  --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
  --add-opens java.base/java.io=ALL-UNNAMED \
  -Drunning.in.docker=true \
  -jar /home/webgoat/webgoat.jar \
  --server.address=0.0.0.0 \
  --webgoat.mail.url=http://127.0.0.1:8080/WebGoat/mail >/dev/null

for _ in $(seq 1 90); do
  if curl --fail --silent http://127.0.0.1:18080/WebGoat/actuator/health >/dev/null \
    && curl --fail --silent -L http://127.0.0.1:19090/WebWolf/ >/dev/null; then
    exit 0
  fi
  sleep 2
done
docker logs "$container" >&2
exit 1
