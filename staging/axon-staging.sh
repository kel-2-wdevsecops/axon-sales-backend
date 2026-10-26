#!/usr/bin/env bash
# axon-staging: satu-satunya perintah yang boleh dijalankan kunci SSH CI di
# VPS staging. Dipasang ke /usr/local/bin/axon-staging dan dikunci lewat
# `command="..."` di authorized_keys user deploy (lihat staging/README.md),
# jadi kunci itu tidak bisa membuka shell, menyalin file, atau port forward.
#
# Perintah (dari SSH_ORIGINAL_COMMAND, atau argumen kalau dijalankan manual):
#   deploy <be|fe> <sha256:...>  tarik image by digest, jalankan, health check,
#                                rollback otomatis bila tidak sehat. Token
#                                registry (GITHUB_TOKEN) dibaca dari stdin dan
#                                hanya hidup di DOCKER_CONFIG sementara.
#   status                       container dan image yang sedang jalan.
#   version                      versi skrip ini.
#
# Exit code deploy: 0 sukses, 1 gagal tanpa rollback, 3 gagal lalu dikembalikan
# ke image sebelumnya, 4 rollback juga gagal.
#
# User deploy ada di grup docker, yang setara root. Pembatasan perintah di sini
# adalah pengaman utamanya: input divalidasi ketat, image hanya dari
# ghcr.io/kel-2-wdevsecops/{be,fe}, dan compose.yaml tidak bisa diganti dari CI.

set -euo pipefail

readonly SCRIPT_VERSION=1
readonly STACK_DIR=${AXON_STAGING_DIR:-/opt/axon-staging}
readonly REGISTRY=ghcr.io
readonly IMAGE_PREFIX=$REGISTRY/kel-2-wdevsecops
readonly ENV_FILE=$STACK_DIR/.env

die() { echo "axon-staging: $*" >&2; exit 1; }

# Nilai KEY dari .env (kosong kalau belum ada).
get_env() {
  [[ -f $ENV_FILE ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

# Ganti/tambah satu baris KEY=VALUE. Baris lain (rahasia) dibiarkan. Ditulis
# ke file sementara (mktemp = mode 600) lalu di-rename, supaya .env tidak
# pernah setengah tertulis.
set_env() {
  local tmp
  tmp=$(mktemp "$STACK_DIR/.env.XXXXXX")
  if [[ -f $ENV_FILE ]]; then grep -v "^$1=" "$ENV_FILE" >"$tmp" || true; fi
  echo "$1=$2" >>"$tmp"
  mv "$tmp" "$ENV_FILE"
  echo "$1=$2"
}

compose() { docker compose "$@"; }

# Sehat = container service menjalankan image yang diminta (bukan container
# lama yang kebetulan masih hidup) DAN endpoint health-nya menjawab benar.
# BE: status "ok" berarti DB tersambung. FE: /version.json tersaji nginx.
healthy() {
  local svc=$1 service=$2 image=$3 attempts=$4 want cid body i
  want=$(docker image inspect --format '{{.Id}}' "$image")
  for ((i = 1; i <= attempts; i++)); do
    sleep 5
    cid=$(compose ps -q "$service" 2>/dev/null || true)
    if [[ -z $cid || $(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null) != "$want" ]]; then
      echo "Percobaan $i: container belum menjalankan image baru."
      continue
    fi
    if [[ $svc == be ]]; then
      body=$(compose exec -T "$service" wget -q -T 5 -O - http://localhost:3008/api/v1/health 2>/dev/null || true)
      if [[ $body == *'"status":"ok"'* ]]; then echo "Sehat: $body"; return 0; fi
    else
      body=$(compose exec -T "$service" wget -q -T 5 -O - http://127.0.0.1:8080/version.json 2>/dev/null || true)
      if [[ $body == *'"version"'* ]]; then echo "Sehat: $body"; return 0; fi
    fi
    echo "Percobaan $i: belum sehat."
  done
  return 1
}

# Sisakan image yang jalan sekarang dan target rollback berikutnya. Disk VPS
# kecil, dan setiap push ke main menghasilkan image baru.
prune_images() {
  local repo=$1 keep_a=$2 keep_b=$3 id
  local -a keep=()
  keep+=("$(docker image inspect --format '{{.Id}}' "$keep_a" 2>/dev/null || true)")
  if [[ -n $keep_b ]]; then keep+=("$(docker image inspect --format '{{.Id}}' "$keep_b" 2>/dev/null || true)"); fi
  while read -r id; do
    [[ -z $id || " ${keep[*]} " == *" $id "* ]] && continue
    docker rmi "$id" >/dev/null 2>&1 || true
  done < <(docker images --no-trunc --quiet "$repo" | sort -u)
}

cmd_deploy() {
  local svc=$1 digest=$2 service var token previous image cfg
  case $svc in
    be) service=devsecops_be var=BE_IMAGE ;;
    fe) service=devsecops_fe var=FE_IMAGE ;;
    *) die "service harus be atau fe" ;;
  esac
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "digest tidak valid"
  image=$IMAGE_PREFIX/$svc@$digest

  # Token dibaca sebelum menunggu lock, supaya stdin SSH tidak menggantung.
  IFS= read -r token || true

  # Repo BE dan FE bisa men-deploy bersamaan (concurrency GitHub hanya per
  # repo), dan keduanya menulis .env yang sama.
  exec 9>"$STACK_DIR/.deploy.lock"
  flock -w 900 9 || die "menunggu deploy lain terlalu lama"

  previous=$(get_env "$var")
  echo "Image sebelumnya: ${previous:-<belum ada>}"

  cfg=$(mktemp -d)
  # shellcheck disable=SC2064 # $cfg sengaja di-expand sekarang.
  trap "rm -rf '$cfg'" EXIT
  if [[ -n $token ]]; then
    printf '%s' "$token" | DOCKER_CONFIG=$cfg docker login "$REGISTRY" -u github-actions --password-stdin >/dev/null
  fi
  DOCKER_CONFIG=$cfg docker pull --quiet "$image"
  rm -rf "$cfg"
  unset token

  set_env "$var" "$image"
  compose up -d --no-deps --pull never "$service"

  if healthy "$svc" "$service" "$image" 24; then
    prune_images "$IMAGE_PREFIX/$svc" "$image" "$previous"
    echo "Deploy staging $svc berhasil: $image"
    exit 0
  fi

  echo "::error::$svc tidak sehat setelah 2 menit."
  compose logs --tail 80 "$service" || true

  if [[ -z $previous || $previous == "$image" ]]; then
    exit 1
  fi
  echo "Rollback ke $previous"
  set_env "$var" "$previous"
  compose up -d --no-deps --pull never "$service"
  if healthy "$svc" "$service" "$previous" 18; then
    exit 3
  fi
  echo "::error::Rollback ke $previous juga tidak sehat."
  exit 4
}

cmd_status() {
  compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Image}}'
  echo
  grep -E '^(BE|FE)_IMAGE=' "$ENV_FILE" || true
  echo
  free -m
}

main() {
  local -a args
  if [[ -n ${SSH_ORIGINAL_COMMAND:-} ]]; then
    # read -a tidak melakukan glob/expansion; setiap kata divalidasi di bawah.
    read -r -a args <<<"$SSH_ORIGINAL_COMMAND"
  else
    args=("$@")
  fi
  cd "$STACK_DIR" || die "$STACK_DIR belum ada"

  case "${args[0]:-}" in
    deploy)
      [[ ${#args[@]} -eq 3 ]] || die "pemakaian: deploy <be|fe> <sha256:...>"
      # Dipanggil langsung (bukan `|| ...`) supaya set -e tetap berlaku di
      # dalamnya; cmd_deploy mengakhiri proses dengan exit code-nya sendiri.
      cmd_deploy "${args[1]}" "${args[2]}"
      ;;
    status) cmd_status ;;
    version) echo "$SCRIPT_VERSION" ;;
    *) die "perintah tidak dikenal (deploy | status | version)" ;;
  esac
}

main "$@"
