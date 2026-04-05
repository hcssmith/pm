#!/usr/bin/env bash

set -euo pipefail

PROJECT_FILE="project.json"

action="${1:-}"

if [[ -z "$action" ]]; then
	echo "Usage: $0 <action>"
	exit 1
fi

# Check action exists
if ! jq -e ".actions | has(\"$action\")" "$PROJECT_FILE" >/dev/null; then
	echo "Action '$action' not found"
	exit 1
fi

src=$(jq -r ".source" "$PROJECT_FILE")
artifact_dir=$(jq -r ".artifact_dir" "$PROJECT_FILE")
name=$(jq -r ".name" "$PROJECT_FILE")

copy_artifacts() {
  local base_dir="$1"
  shift
  local artifacts=("$@")

  if [[ ${#artifacts[@]} -gt 0 ]]; then
    mkdir -p "$artifact_dir"
    for artifact in "${artifacts[@]}"; do
      echo "==> Copying artifact: $artifact"
      cp -r "$base_dir/$artifact" "$artifact_dir/"
    done
  fi
}


run_native() {
	config=$1
	artifact_dir=$(jq -r ".artifact_dir" "$PROJECT_FILE")

	mapfile -t steps < <(echo "$config" | jq -r ".steps[]")
  local artifacts=()
	mapfile -t artifacts < <(echo "$config" | jq -r ".artifacts[]? // empty")

  echo "=> Running Native Action" 
  echo "==> Building"
	pushd "$src" > /dev/null
	for step in "${steps[@]}"; do
		echo "-> $step"
		bash -c "$step"
	done
	popd >/dev/null

  if [[ ${#artifacts[@]} -gt 0 ]]; then
    copy_artifacts $src $artifacts
  fi
}

run_docker() {
  local config=$1
  local workdir tag dockerfile cmd
  workdir=$(echo "$config" | jq -r ".workdir")
  cmd=$(echo "$config" | jq -r ".cmd")
  local artifacts=()
  mapfile -t artifacts < <(echo "$config" | jq -r ".artifacts[]? // empty")
  tag=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  dockerfile=$(mktemp)
  echo "==> Generating Dockerfile"

  {
    echo "FROM $(echo "$config" | jq -r ".image")"
    echo "WORKDIR $(echo "$config" | jq -r ".workdir")"

    echo "$config" | jq -r ".steps[]"

  } > "$dockerfile"
  
  docker build -f "$dockerfile" -t "$tag-builder" "$src"

  rm "$dockerfile"

  docker run --rm -i \
    -u "$(id -u):$(id -g)" \
    -v "$src:$workdir" \
    -w "$workdir" \
    -e GOCACHE=/tmp/go-build \
    -e GOMODCACHE=/tmp/go-mod \
    "$tag-builder" \
    bash -c "$cmd"
  
  if [[ ${#artifacts[@]} -gt 0 ]]; then
    copy_artifacts "$src" $artifacts
  fi

}

run_action() {
	local action_name="$1"

	local config
	config=$(jq ".actions[\"$action_name\"]" "$PROJECT_FILE")

	local atype
	atype=$(echo "$config" | jq -r ".type")

	case "$atype" in
	native)
		run_native "$config"
		;;
	docker)
		run_docker "$config"
		;;
	esac
}

run_action "$action"
