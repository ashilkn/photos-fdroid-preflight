#!/usr/bin/env bash
set -euo pipefail

if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ||
      ${GITHUB_REPOSITORY:-} != ashilkn/photos-fdroid-preflight || ${RUNNER_OS:-} != Linux ||
      $(uname -m) != x86_64 ]]; then
  printf '%s\n' 'This script requires the dedicated GitHub-hosted Linux runner.' >&2
  exit 64
fi

readarray -t parameters < <(python3 - <<'PY'
import json
import re

with open("provenance.json") as f:
    m = json.load(f)
with open("diagnostics/probe.json") as f:
    assert json.load(f)["capacity_suitable"]
for key in ["gitlab_commit", "source_sha", "fdroidserver_commit", "selected_metadata_sha256"]:
    assert re.fullmatch("[0-9a-f]{40}" if key != "selected_metadata_sha256" else "[0-9a-f]{64}", m[key])
assert m["gitlab_repository"] == "https://gitlab.com/ashilkn99/fdroiddata.git"
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", m["version_name"])
assert isinstance(m["version_code"], int) and m["version_code"] > 0
assert m["no_tarball"] is True
assert re.fullmatch(r"[A-Za-z0-9_/-]+", m["gitlab_branch"])
for key in ["gitlab_repository", "gitlab_commit", "image", "fdroidserver_commit", "source_sha", "version_name", "version_code", "selected_metadata_sha256", "gitlab_branch"]:
    print(m[key])
PY
)
[[ ${#parameters[@]} == 9 ]]
repository=${parameters[0]}
recipe=${parameters[1]}
image=${parameters[2]}
server=${parameters[3]}
source_sha=${parameters[4]}
version_name=${parameters[5]}
version_code=${parameters[6]}
selected_hash=${parameters[7]}
recipe_branch=${parameters[8]}

git init builder
git -C builder remote add origin "$repository"
git -C builder fetch --depth=5000 origin "$recipe"
git -C builder checkout --detach FETCH_HEAD
[[ $(git -C builder rev-parse HEAD) == "$recipe" ]]
python3 - <<'PY'
import hashlib
import json
from pathlib import Path

m = json.loads(Path("provenance.json").read_text())
for name, expected in m["file_sha256"].items():
    actual = hashlib.sha256((Path("builder") / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"Recipe input changed: {name}")
Path("diagnostics/recipe-inputs-verified.json").write_text(json.dumps(m, indent=2) + "\n")
PY

docker run --rm --platform linux/amd64 --entrypoint /bin/bash \
  --volume "$PWD/builder:/workspace/fdroiddata" --workdir /workspace/fdroiddata \
  "$image" -ceu '
    python3 preflight/prepare.py --case candidate --metadata preflight/candidate.yml \
      --output preflight-results/expected --source "$1" --version-name "$2" --version-code "$3"
    printf "%s  %s\n" "$4" preflight-results/expected/io.ente.photos.fdroid.yml | sha256sum -c -
  ' bash "$source_sha" "$version_name" "$version_code" "$selected_hash"

remaining=$(( $(cat diagnostics/start-epoch) + 20700 - $(date +%s) ))
(( remaining > 0 ))
printf '%s\n' "$remaining" > diagnostics/build-timeout-seconds.txt

finish() {
  status=$?
  trap - EXIT
  if [[ -f diagnostics/build.cid ]]; then
    docker stop --time 120 "$(cat diagnostics/build.cid)" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$status" > diagnostics/driver-exit-code.txt
  date -u +%FT%TZ > diagnostics/finished-at.txt
  df -B1 . > diagnostics/disk-final.txt
  exit "$status"
}
trap finish EXIT

set +e
timeout --signal=TERM --kill-after=120s "${remaining}s" \
  docker run --rm --init --platform linux/amd64 --user 0 \
    --cidfile "$PWD/diagnostics/build.cid" \
    --volume "$PWD/builder:/workspace/fdroiddata" --workdir /workspace/fdroiddata \
    --env CI_PROJECT_PATH=ashilkn99/fdroiddata \
    --env "CI_COMMIT_BRANCH=$recipe_branch" \
    --env CI_PIPELINE_SOURCE=api --env CI_PROJECT_DIR=/workspace/fdroiddata \
    --env "CI_COMMIT_SHA=$recipe" --env "CI_JOB_IMAGE=$image" \
    --env PREFLIGHT_CASE=candidate --env NO_TARBALL=true \
    --env "FDROIDSERVER_COMMIT=$server" --env "SOURCE_COMMIT=$source_sha" \
    --env "VERSION_NAME=$version_name" --env "VERSION_CODE=$version_code" \
    --entrypoint /bin/bash "$image" preflight/run.sh \
    2>&1 | tee diagnostics/container.log
status=${PIPESTATUS[0]}
set -e
exit "$status"
