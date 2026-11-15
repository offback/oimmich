#!/usr/bin/env bash
# immich.sh — the only part of the plugin that talks to Immich.
#
# QML cannot set request headers on Image.source and Quickshell has no HTTP
# client, so all network and cache work happens here and the overlay only ever
# reads local files. Runs inside the shell process, so nothing may block: each
# call does one bounded thing and exits.
#
#   immich.sh check  <config.json>            verify server, key and permissions
#   immich.sh list   <config.json> [--force]  asset manifest (JSON array on stdout)
#   immich.sh fetch  <config.json> <asset-id> one preview into the cache, prints its path
#   immich.sh prune  <config.json>            evict oldest files over the size cap
#
# Config comes from scripts/config-to-json.lua, already merged and validated.

set -euo pipefail

CMD=${1:-}
CFG=${2:-}
ARG=${3:-}

die() { printf '%s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

[[ -n $CMD && -n $CFG ]] || die "usage: immich.sh <check|list|fetch|prune> <config.json|config.lua> [arg]"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Accept the user's config.lua directly. QML cannot write files, and piping the
# merged config through stdin would need a close the caller cannot perform, so
# the merged copy is written here, where the cache dir is already known.
if [[ $CFG == *.lua ]]; then
  merged=$(lua "$SCRIPT_DIR/config-to-json.lua" "$CFG") || die "config loader failed: $CFG"
  errors=$(jq -r '(.meta.errors // []) | join("; ")' <<<"$merged")
  [[ -z $errors ]] || die "config errors: $errors"
  cache=$(jq -r '.config.cache.dir // empty' <<<"$merged")
  [[ -n $cache ]] || die "config has no cache.dir"
  mkdir -p "$cache"
  jq -c '{config: .config}' <<<"$merged" > "$cache/config.json.tmp.$$" &&
    mv -f "$cache/config.json.tmp.$$" "$cache/config.json"
  CFG="$cache/config.json"
fi

[[ -r $CFG ]] || die "cannot read config: $CFG"

jqr() { jq -r "$1" "$CFG"; }

URL=$(jqr '.config.server.url')
KEY_FILE=$(jqr '.config.server.api_key_file')
VERIFY_TLS=$(jqr '.config.server.verify_tls')
QUALITY=$(jqr '.config.sizing.quality')
CACHE_DIR=$(jqr '.config.cache.dir')
MAX_GB=$(jqr '.config.cache.max_gb')
REFRESH_MIN=$(jqr '.config.cache.refresh_minutes')
STILLS_ONLY=$(jqr '.config.source.stills_only')
MODE=$(jqr '.config.source.mode')
FROM=$(jqr '.config.source.from // empty')
TO=$(jqr '.config.source.to // empty')
ALBUMS=$(jq -c '.config.source.albums // []' "$CFG")

[[ -r $KEY_FILE ]] || die "API key file not readable: $KEY_FILE (see README: create it 0600)"
KEY=$(tr -d '[:space:]' < "$KEY_FILE")
[[ -n $KEY ]] || die "API key file is empty: $KEY_FILE"

MANIFEST="$CACHE_DIR/manifest.json"
MANIFEST_STAMP="$CACHE_DIR/manifest.json.at"
IMG_DIR="$CACHE_DIR/img"
mkdir -p "$IMG_DIR"

CURL_BASE=(curl -sS --connect-timeout 5 --max-time 45 --retry 2 --retry-delay 1
           -H "x-api-key: $KEY" -H 'accept: application/json')
[[ $VERIFY_TLS == "false" ]] && CURL_BASE+=(-k)
# --fail-with-body for API JSON so an HTML error page is never parsed as data;
# the image fetch needs the status code instead, so it uses the bare array.
CURL=("${CURL_BASE[@]}" --fail-with-body)

# Never let an API response or a config value become shell syntax: ids and
# paths are passed as argv and validated before they touch the filesystem.
is_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

api_get() { "${CURL[@]}" "$URL$1"; }

api_post() { "${CURL[@]}" -H 'content-type: application/json' -d "$2" "$URL$1"; }

# ---------------------------------------------------------------- check

cmd_check() {
  printf 'server  %s\n' "$URL"
  local version
  version=$(api_get /api/server/version | jq -r '"\(.major).\(.minor).\(.patch)"') || die "cannot reach $URL"
  printf 'version %s\n' "$version"

  local albums
  albums=$(api_get /api/albums) || die "album.read missing or key rejected"
  printf 'albums  %s  (album.read ok)\n' "$(jq 'length' <<<"$albums")"

  local one
  one=$(api_post /api/search/metadata '{"size":1,"type":"IMAGE"}') || die "asset.read missing"
  printf 'assets  readable  (asset.read ok)\n'

  local id
  id=$(jq -r '.assets.items[0].id // empty' <<<"$one")
  [[ -n $id ]] || die "no images in this library"

  local tmp code
  tmp=$(mktemp)
  code=$("${CURL[@]}" -o "$tmp" -w '%{http_code}' "$URL/api/assets/$id/thumbnail?size=$QUALITY") || true
  local bytes
  bytes=$(wc -c < "$tmp")
  rm -f "$tmp"
  [[ $code == 200 ]] || die "thumbnail fetch failed (http $code) - asset.view may be missing"
  printf 'images  %s bytes for one %s  (asset.view ok)\n' "$bytes" "$QUALITY"
}

# ---------------------------------------------------------------- list

build_manifest() {
  local tmp_raw
  tmp_raw=$(mktemp)
  trap 'rm -f "$tmp_raw"' RETURN

  # Album references may be UUIDs or names; resolve names once through the album
  # list, then let the search endpoint page and filter in a single code path.
  local -a album_ids=()
  local album_count ref id all_albums
  album_count=$(jq 'length' <<<"$ALBUMS")
  if (( album_count > 0 )); then
    all_albums=$(api_get /api/albums)
    while IFS= read -r ref; do
      if is_uuid "$ref"; then
        id=$ref
      else
        id=$(jq -r --arg n "$ref" '.[] | select(.albumName == $n) | .id' <<<"$all_albums" | head -1)
        [[ -n $id ]] || die "album not found: $ref"
      fi
      album_ids+=("$id")
    done <<<"$(jq -r '.[]' <<<"$ALBUMS")"
  fi

  local filter_json="{}"
  if (( ${#album_ids[@]} > 0 )); then
    filter_json=$(printf '%s\n' "${album_ids[@]}" | jq -R . | jq -s -c '{albumIds:{all:.}}')
  fi

  # Whole library (or the chosen albums), paged. A page that comes back short is
  # retried before it is believed: the server can return a partial page under
  # load, and silently stopping there would cache a truncated library for the
  # whole refresh interval. Anything still wrong fails the build rather than
  # writing a manifest that quietly lost photos.
  local page=1 page_json count=0 body items tries
  while (( page <= 200 )); do
    body=$(jq -cn --argjson f "$filter_json" --argjson p "$page" \
      '{size:1000, page:$p, type:"IMAGE"}
       + (if ($f | length) > 0 then {filter: $f} else {} end)')

    tries=0
    while :; do
      tries=$((tries + 1))
      page_json=$(api_post /api/search/metadata "$body") || page_json=""
      count=$(jq -er '.assets.count' <<<"${page_json:-{\}}" 2>/dev/null) || count=-1
      items=$(jq -er '.assets.items | length' <<<"${page_json:-{\}}" 2>/dev/null) || items=-1
      (( count >= 0 && items == count )) && break
      if (( tries >= 3 )); then
        die "page $page failed after $tries attempts (items=$items count=$count)"
      fi
      sleep $(( tries * 2 ))
    done

    (( count == 0 )) && break
    jq -c '.assets.items[] | {id, w: .width, h: .height, mime: .originalMimeType,
           type, date: .fileCreatedAt, name: .originalFileName}' <<<"$page_json" >> "$tmp_raw"
    # A short-but-non-empty page is not the end: the server has been seen to
    # return 672 on one page and full pages after it, and treating that as the
    # last page silently dropped fifteen thousand photos from the manifest. Only
    # an empty page ends the walk.
    page=$((page + 1))
  done
  (( page > 400 )) && note "warning: manifest stopped at the 400 page cap"

  # Dedupe (an asset can sit in two albums), drop macOS AppleDouble stubs like
  # "._IMG_0109.jpg" (they carry no media and 404 on every fetch), drop anything
  # not a still, apply the date window, then order per config.
  jq -s \
     --argjson stills "$STILLS_ONLY" \
     --arg from "$FROM" --arg to "$TO" \
     --arg mode "$MODE" '
     [ .[] | select(.id != null) ]
     | unique_by(.id)
     | map(select((.name // "") | test("^\\.[_]") | not))
     | map(select(.mime != null and (.mime | startswith("image/"))))
     | if $stills then map(select(.type != "VIDEO")) else . end
     | map(select(($from == "") or (.date >= $from)))
     | map(select(($to   == "") or (.date <= ($to + "T23:59:59.999Z"))))
     | (if $mode == "newest" then sort_by(.date) | reverse
        elif $mode == "oldest" then sort_by(.date)
        else . end)
     | map({id, w, h, mime, date})' "$tmp_raw"
}

cmd_list() {
  local force=0
  [[ ${ARG:-} == "--force" ]] && force=1

  if (( ! force )) && [[ -s $MANIFEST && -s $MANIFEST_STAMP ]]; then
    local age
    age=$(( $(date +%s) - $(cat "$MANIFEST_STAMP") ))
    if (( age < REFRESH_MIN * 60 )); then
      cat "$MANIFEST"
      return 0
    fi
  fi

  local out tmp
  out=$(build_manifest) || die "manifest build failed"
  tmp=$(mktemp "$MANIFEST.XXXXXX")
  printf '%s\n' "$out" > "$tmp"
  mv -f "$tmp" "$MANIFEST"
  date +%s > "$MANIFEST_STAMP"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------- fetch

# content-type decides the extension: Qt derives the loader from it in some
# paths, and a .img file with no hint is the classic "image never appears" bug.
ext_for() {
  case $1 in
    image/jpeg | image/jpg) printf 'jpg' ;;
    image/webp) printf 'webp' ;;
    image/png) printf 'png' ;;
    image/avif) printf 'avif' ;;
    image/heic | image/heif) printf 'heic' ;;
    *) printf 'jpg' ;;
  esac
}

cmd_fetch() {
  local id=${ARG:-}
  is_uuid "$id" || die "fetch needs a UUID asset id, got: $id"

  local existing
  existing=$(find "$IMG_DIR" -maxdepth 1 -name "$id.*" -print -quit)
  if [[ -n $existing && -s $existing ]]; then
    touch "$existing"   # LRU: usage is recency
    printf '%s\n' "$existing"
    return 0
  fi

  local tmp hdr code ctype
  tmp=$(mktemp "$IMG_DIR/.$id.XXXXXX")
  hdr=$(mktemp)
  code=$("${CURL_BASE[@]}" -o "$tmp" -D "$hdr" -w '%{http_code}' "$URL/api/assets/$id/thumbnail?size=$QUALITY") || true
  ctype=$(awk 'BEGIN{IGNORECASE=1} /^content-type:/ { gsub(/\r/,""); print $2; exit }' "$hdr")
  rm -f "$hdr"

  # 404 is "this asset has no media" (an AppleDouble stub, a broken import). The
  # caller drops the id and moves on rather than treating it as fatal.
  if [[ $code == 404 ]]; then
    rm -f "$tmp"
    note "missing-media $id"
    exit 3
  fi
  [[ $code == 200 ]] || { rm -f "$tmp"; die "download failed for $id (http $code)"; }
  [[ -n $ctype ]] || ctype=image/jpeg

  # A JSON body or an empty file here means a permission or server problem, not
  # a photo; refuse rather than caching the error page as an image.
  if [[ $ctype != image/* ]] || (( $(wc -c < "$tmp") < 1024 )); then
    rm -f "$tmp"
    die "not an image ($ctype) for $id"
  fi

  local dest="$IMG_DIR/$id.$(ext_for "$ctype")"
  mv -f "$tmp" "$dest"
  printf '%s\n' "$dest"
}

# ---------------------------------------------------------------- prune

cmd_prune() {
  local cap_bytes used
  cap_bytes=$(awk -v g="$MAX_GB" 'BEGIN { printf "%d", g * 1024 * 1024 * 1024 }')
  used=$(du -sb "$CACHE_DIR" 2>/dev/null | cut -f1)
  (( used > cap_bytes )) || { note "cache ok: $(( used / 1048576 )) MB / $(( cap_bytes / 1048576 )) MB"; return 0; }

  local removed=0
  # Oldest access first; touch-on-fetch above keeps this a real LRU.
  while IFS= read -r f; do
    (( used <= cap_bytes )) && break
    local sz
    sz=$(stat -c %s "$f")
    rm -f "$f"
    used=$(( used - sz ))
    removed=$((removed + 1))
  done < <(find "$IMG_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)

  note "pruned $removed file(s); cache now $(( used / 1048576 )) MB / $(( cap_bytes / 1048576 )) MB"
}

case $CMD in
  check)  cmd_check ;;
  list)   cmd_list ;;
  fetch)  cmd_fetch ;;
  prune)  cmd_prune ;;
  *)      die "unknown command: $CMD" ;;
esac
