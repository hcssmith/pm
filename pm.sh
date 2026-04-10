#!/usr/bin/env bash

set -euo pipefail

PROJECT_FILE="project.json"

action="${1:-}"

if [[ -z "$action" ]]; then
	echo "Usage: $0 <action>"
	echo ""
	echo "Special commands:"
	echo "  list    Show available actions"
	echo "  agent   Launch AI dev agent (if configured)"
	echo ""
	echo "Run '$0 list' to see all project actions."
	exit 1
fi

# field validation

for field in "name" "source" "artifact_dir"; do
  val=$(jq -r ".$field" "$PROJECT_FILE")
  if [[ "$val" == "null" || -z "$val" ]]; then
    echo "$field not set"
    exit 1
  fi
done

# Resolve shared fields
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
    copy_artifacts "$src" "${artifacts[@]}"
  fi
}

run_docker() {
  local action=$1
  local config=$2
  local workdir tag dockerfile cmd
  workdir=$(echo "$config" | jq -r ".workdir")
  cmd=$(echo "$config" | jq -r ".cmd")
  if [[ -z "$cmd" ]]; then
    echo "No command Specified"
    exit 1
  fi


  local artifacts=()
  mapfile -t artifacts < <(echo "$config" | jq -r ".artifacts[]? // empty")
  tag=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

  # Parse cache_volumes into mount strings (before Dockerfile generation)
  local vol_mounts=()
  mapfile -t vol_mounts < <(echo "$config" | jq -r --arg tag "$tag" \
    '.cache_volumes // {} | to_entries[] | "pm-\($tag)__\(.key):\(.value)"')

  local vol_args=()
  for m in "${vol_mounts[@]}"; do
    vol_args+=(-v "$m")
  done

  # Extract container paths for Dockerfile mkdir
  local cache_paths=()
  mapfile -t cache_paths < <(echo "$config" | jq -r '.cache_volumes // {} | to_entries[] | .value')

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
  mapfile -t env_entries < <(echo "$config" | jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"')
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

  local run_args=(--rm -i)
  if echo "$config" | jq -e '.interactive' >/dev/null 2>&1; then
    run_args+=(-t)
  fi

  docker run "${run_args[@]}" \
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
    copy_artifacts "$src" "${artifacts[@]}"
  fi

}

run_agent() {
  local config
  config=$(jq '.agent' "$PROJECT_FILE")

  local base_image
  base_image=$(echo "$config" | jq -r '.base_image // "pi-agent"')
  local tag
  tag=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

  # Handle custom instructions — file path or raw text
  local instructions cleanup_file=''
  instructions=$(echo "$config" | jq -r '.instructions // empty')
  local instructions_copy=''
  if [[ -n "$instructions" ]]; then
    if [[ -f "$instructions" ]]; then
      # It's a file path — copy into build context so Docker can access it
      cleanup_file="$(mktemp -p "$src" tmp.agent.instructions.XXXXXX.md)"
      cp "$(readlink -f "$instructions")" "$cleanup_file"
      instructions_copy="COPY ${cleanup_file##*/} /home/pi/.pi/agent/AGENTS.md"
    else
      # It's raw text — write to temp file in build context
      cleanup_file="$(mktemp -p "$src" tmp.agent.instructions.XXXXXX.md)"
      echo "$instructions" > "$cleanup_file"
      instructions_copy="COPY ${cleanup_file##*/} /home/pi/.pi/agent/AGENTS.md"
    fi
  fi

  local dockerfile
  dockerfile=$(mktemp)
  echo "==> Generating agent Dockerfile"

  {
    echo "FROM $base_image"
    echo "USER root"
    echo "$config" | jq -r '.steps[]'
    if [[ -n "$instructions_copy" ]]; then
      echo "$instructions_copy"
      echo "RUN chown pi:pi /home/pi/.pi/agent/AGENTS.md"
    fi
    echo "USER pi"
  } > "$dockerfile"

  echo "==> Building agent image"
  docker build --provenance=false -f "$dockerfile" -t "$tag-agent" "$src"
  rm "$dockerfile"
  # Clean up temp instructions file if we created one
  if [[ -n "$cleanup_file" ]]; then
    rm -f "$cleanup_file"
  fi

  echo "==> Launching agent container"

  # Build volume mounts
  local vol_args=("-v" "$src:/app")

  # Named volume for persistent sessions (scoped per project)
  vol_args+=("-v" "pm-${tag}__sessions:/home/pi/.pi/agent/sessions")

  # Mount models.json if it exists (read-only)
  local models_json="$HOME/.pi/agent/models.json"
  if [[ -f "$models_json" ]]; then
    vol_args+=("-v" "$models_json:/home/pi/.pi/agent/models.json:ro")
  fi

  # Pass through API key env vars if set
  local env_args=()
  for var in ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY; do
    if [[ -n "${!var:-}" ]]; then
      env_args+=("-e" "${var}=${!var}")
    fi
  done

  [[ -t 1 ]] && clear

  docker run -it --rm --init \
    --name "$tag-agent" \
    "${vol_args[@]}" \
    "${env_args[@]}" \
    -e "TERM=${TERM:-xterm-256color}" \
    "$tag-agent"
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

run_list() {
  local has_agent=''
  if jq -e 'has("agent")' "$PROJECT_FILE" >/dev/null 2>&1; then
    has_agent=1
  fi

  # Collect all rows into arrays for aligned formatting
  local names=() descs=()

  if [[ -n "$has_agent" ]]; then
    names+=("agent")
    descs+=("AI dev agent")
  fi

  local action_names
  mapfile -t action_names < <(jq -r '.actions | keys[]' "$PROJECT_FILE")
  for a in "${action_names[@]}"; do
    local desc=''
    desc=$(jq -r ".actions[\"$a\"].description // empty" "$PROJECT_FILE")
    if [[ -z "$desc" ]]; then
      local atype
      atype=$(jq -r ".actions[\"$a\"].type" "$PROJECT_FILE")
      desc="[${atype}]"
    fi
    names+=("$a")
    descs+=("$desc")
  done

  # Find max name length for alignment
  local max_len=0
  for n in "${names[@]}"; do
    if [[ ${#n} -gt $max_len ]]; then
      max_len=${#n}
    fi
  done

  local B='\033[1m' R='\033[0m'

  echo -e "${B}${name}${R}"
  echo ""
  for i in "${!names[@]}"; do
    printf "  ${B}%-${max_len}s${R}   %s\n" "${names[$i]}" "${descs[$i]}"
  done
}

# Dispatch
if [[ "$action" == "list" ]]; then
	run_list
elif [[ "$action" == "agent" ]] && jq -e 'has("agent")' "$PROJECT_FILE" >/dev/null; then
	run_agent
elif jq -e ".actions | has(\"$action\")" "$PROJECT_FILE" >/dev/null; then
	run_action "$action"
else
	echo "Action '$action' not found"
	echo "Run '$0 list' to see available actions."
	exit 1
fi
