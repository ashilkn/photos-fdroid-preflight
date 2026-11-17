#!/usr/bin/env bash
set -euo pipefail

if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ||
      ${GITHUB_REPOSITORY:-} != ashilkn/photos-fdroid-preflight || ${RUNNER_OS:-} != Linux ||
      $(uname -m) != x86_64 ]]; then
  printf '%s\n' 'This script requires the dedicated GitHub-hosted Linux runner.' >&2
  exit 64
fi
[[ ${REQUEST_ID:-} =~ ^[a-zA-Z0-9_-]+$ ]]

mkdir -p diagnostics
date +%s > diagnostics/start-epoch
cp provenance.json diagnostics/provenance.json
{
  uname -a
  nproc
  free -b
  df -B1 .
  docker version
  sudo du -sk /usr/local/lib/android /usr/share/dotnet /opt/ghc \
    /usr/local/share/boost /usr/share/swift /opt/hostedtoolcache/CodeQL 2>/dev/null || true
} > diagnostics/host-before.txt

sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc \
  /usr/local/share/boost /usr/share/swift /opt/hostedtoolcache/CodeQL
docker system prune --all --force > diagnostics/docker-cleanup.txt
df -B1 . > diagnostics/disk-after-cleanup.txt

image=$(python3 -c 'import json; print(json.load(open("provenance.json"))["image"])')
docker pull --platform linux/amd64 "$image"
docker image inspect "$image" --format '{{json .RepoDigests}}' > diagnostics/image-digests.json
docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}' > diagnostics/image-platform.txt
[[ $(cat diagnostics/image-platform.txt) == linux/amd64 ]]

docker run --rm --platform linux/amd64 --entrypoint /bin/bash "$image" -ceu '
  export ANDROID_HOME=/opt/android-sdk TERM=xterm
  source /etc/profile.d/bsenv.sh
  [[ $home_vagrant == /home/vagrant ]]
  command -v apt-get runuser git python3
  python3 --version
  git --version
  nproc
  free -b
  git -C "$home_vagrant/gradlew-fdroid" rev-parse HEAD
  test -d /opt/android-sdk
' > diagnostics/toolchain.txt

python3 - <<'PY'
import datetime
import json
import os
import shutil

with open("provenance.json") as f:
    manifest = json.load(f)
disk = shutil.disk_usage(".")
required = manifest["required_free_bytes_after_image"]
report = {
    "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "runner_architecture": "x86_64",
    "cpu_count": os.cpu_count(),
    "disk_total_bytes": disk.total,
    "disk_free_bytes_after_image": disk.free,
    "required_free_bytes_after_image": required,
    "capacity_suitable": disk.free >= required,
    "image": manifest["image"],
    "request_id": os.environ["REQUEST_ID"],
    "github_repository": os.environ["GITHUB_REPOSITORY"],
    "github_commit": os.environ["GITHUB_SHA"],
    "github_run_id": os.environ["GITHUB_RUN_ID"],
    "github_run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
}
with open("diagnostics/probe.json", "w") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
print(json.dumps(report))
if not report["capacity_suitable"]:
    raise SystemExit("Insufficient free disk for the full preflight; no app build started")
PY
