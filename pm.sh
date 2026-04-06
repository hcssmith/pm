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
  local action=$1
  local config=$2
  local workdir tag dockerfile cmd
  workdir=$(echo "$config" | jq -r ".workdir")
  cmd=$(echo "$config" | jq -r ".cmd")
  local artifacts=()
  mapfile -t artifacts < <(echo "$config" | jq -r ".artifacts[]? // empty")
  tag=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

  # Parse cache_volumes into mount strings (before Dockerfile generation)
  local vol_mounts=()
  mapfile -t vol_mounts < <(echo "$config" | jq -r --arg tag "$tag" \
    '.cache_volumes | to_entries[] | "pm-\($tag)__\(.key):\(.value)"')

  local vol_args=()
  for m in "${vol_mounts[@]}"; do
    vol_args+=(-v "$m")
  done

  # Extract container paths for Dockerfile mkdir
  local cache_paths=()
  mapfile -t cache_paths < <(echo "$config" | jq -r '.cache_volumes | to_entries[] | .value')

  dockerfile=$(mktemp)
  echo "==> Generating Dockerfile"

  {
    echo "FROM $(echo "$config" | jq -r ".image")"
    echo "WORKDIR $(echo "$config" | jq -r ".workdir")"

    # Ensure cache volume dirs exist with open permissions
    for p in "${cache_paths[@]}"; do
      echo "RUN mkdir -p '$p' && chmod a+rw '$p'"
    done

    echo "$config" | jq -r ".steps[]"

  } > "$dockerfile"
  
  docker build --provenance=false -f "$dockerfile" -t "$tag-builder" "$src"

  rm "$dockerfile"

  # Parse env vars from config
  local env_args=()
  mapfile -t env_entries < <(echo "$config" | jq -r '.env | to_entries[] | "\(.key)=\(.value)"')
  for e in "${env_entries[@]}"; do
    env_args+=(-e "$e")
  done

  # Image change detection via fingerprint
  local new_image_id
  new_image_id=$(docker inspect --format='{{.Id}}' "$tag-builder")

  local cache_dir=".pm-cache"
  local fp_file="$cache_dir/${action}.fingerprint"
  mkdir -p "$cache_dir"

  if [[ -f "$fp_file" ]]; then
    local old_image_id
    old_image_id=$(cat "$fp_file")
    if [[ "$old_image_id" != "$new_image_id" ]]; then
      echo "==> Image changed, invalidating cache volumes"
      for m in "${vol_mounts[@]}"; do
        local vol_name="${m%%:*}"
        echo "  Removing volume: $vol_name"
        docker volume rm "$vol_name" 2>/dev/null || true
      done
    fi
  fi

  local tty_flag=''
  if echo "$config" | jq -e '.interactive' >/dev/null 2>&1; then
    tty_flag='-t'
  fi

  docker run --rm -i $tty_flag \
    -u "$(id -u):$(id -g)" \
    -v "$src:$workdir" \
    "${vol_args[@]}" \
    "${env_args[@]}" \
    -w "$workdir" \
    "$tag-builder" \
    bash -c "$cmd"

  # Only save fingerprint after successful build
  echo "$new_image_id" > "$fp_file"
  
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
		run_docker "$action_name" "$config"
		;;
	esac
}

run_action "$action"
