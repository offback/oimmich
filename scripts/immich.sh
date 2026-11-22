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
#
# Every value below is then read from SNAP, one immutable copy of that JSON.
# Helpers overlap by design (a fetch, a manifest refresh and a prune can run at
# once) and each of them rewrites cache/config.json, so two separate reads of
# that file could pair the old server URL with the new API key file — and send
# the new key to the old server. One snapshot makes that impossible.
SNAP=""
if [[ $CFG == *.lua ]]; then
  merged=$(lua "$SCRIPT_DIR/config-to-json.lua" "$CFG") || die "config loader failed: $CFG"
  errors=$(jq -r '(.meta.errors // []) | join("; ")' <<<"$merged")
  [[ -z $errors ]] || die "config errors: $errors"
  cache=$(jq -r '.config.cache.dir // empty' <<<"$merged")
  [[ -n $cache ]] || die "config has no cache.dir"
  mkdir -p "$cache"
  SNAP=$(jq -c '{config: .config}' <<<"$merged")
  # Still written, for tooling and for `jq .` by hand; never read back.
  printf '%s\n' "$SNAP" > "$cache/config.json.tmp.$$" &&
    mv -f "$cache/config.json.tmp.$$" "$cache/config.json"
else
  [[ -r $CFG ]] || die "cannot read config: $CFG"
  SNAP=$(cat -- "$CFG")
fi
[[ -n $SNAP ]] || die "empty config: $CFG"

jqr() { jq -r "$1" <<<"$SNAP"; }

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
ALBUMS=$(jq -c '.config.source.albums // []' <<<"$SNAP")
# A malformed albums value would be read as "no selection"; refuse it rather
# than quietly walking the whole library.
jq -e 'type == "array"' <<<"$ALBUMS" >/dev/null || die "config source.albums must be a list"

[[ -r $KEY_FILE ]] || die "API key file not readable: $KEY_FILE (see README: create it 0600)"
KEY=$(tr -d '[:space:]' < "$KEY_FILE")
[[ -n $KEY ]] || die "API key file is empty: $KEY_FILE"

MANIFEST="$CACHE_DIR/manifest.json"
MANIFEST_STAMP="$CACHE_DIR/manifest.json.at"
# Signature of the source selection. A cached manifest is only valid for the
# albums/date window/filters it was built from: without this, editing
# source.albums in config.lua changed nothing until the cache aged out, which
# reads as "my config is ignored".
MANIFEST_SRC="$CACHE_DIR/manifest.json.src"
# Which server and key filled this cache. A cache is not portable between
# servers, and it is not portable between accounts on the same server.
ORIGIN_FILE="$CACHE_DIR/origin"
IMG_DIR="$CACHE_DIR/img"
mkdir -p "$IMG_DIR"

# Bind the cache to its origin before anything is fetched. Without this, changing
# server.url or the key left a still-fresh manifest and its images in place: the
# previous library kept being shown under the new configuration, restarts
# included, because an unreachable new server just means "keep the old manifest".
# The key itself is never stored — only the first 16 hex digits of its sha256.
ORIGIN=$(printf '%s\n%s\n' "$URL" "$(printf '%s' "$KEY" | sha256sum | cut -c1-16)" |
         sha256sum | cut -d' ' -f1)
if [[ ! -f $ORIGIN_FILE || $(cat "$ORIGIN_FILE" 2>/dev/null) != "$ORIGIN" ]]; then
  had_cache=0
  if [[ -s $MANIFEST ]]; then had_cache=1; fi
  # In-flight downloads use a leading-dot temp name; leave those alone.
  if [[ -n $(find "$IMG_DIR" -maxdepth 1 -type f ! -name '.*' -print -quit) ]]; then
    had_cache=1
  fi
  find "$IMG_DIR" -maxdepth 1 -type f ! -name '.*' -delete 2>/dev/null || true
  rm -f "$MANIFEST" "$MANIFEST_STAMP" "$MANIFEST_SRC"
  printf '%s\n' "$ORIGIN" > "$ORIGIN_FILE.tmp.$$" && mv -f "$ORIGIN_FILE.tmp.$$" "$ORIGIN_FILE"
  if (( had_cache )); then note "cache reset: server or api key changed"; fi
fi

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
        album_ids+=("$ref")
      else
        # A name can match more than one album (Immich happily holds two called
        # "Camera"), and silently taking the first would hide half the photos:
        # add every match.
        mapfile -t matched < <(jq -r --arg n "$ref" '.[] | select(.albumName == $n) | .id' <<<"$all_albums")
        (( ${#matched[@]} > 0 )) || die "album not found: $ref"
        album_ids+=("${matched[@]}")
      fi
    done <<<"$(jq -r '.[]' <<<"$ALBUMS")"
  fi

  local filter_json="{}"
  if (( ${#album_ids[@]} > 0 )); then
    # `any` is the union: photos from any of the chosen albums. `all` would mean
    # "in every one of them", which is empty for two unrelated albums.
    filter_json=$(printf '%s\n' "${album_ids[@]}" | jq -R . | jq -s -c '{albumIds:{any:.}}')
  fi

  # Two paging shapes, because Immich 3.2 moved to cursors: a `filter` object
  # cannot be combined with the deprecated `page` field (the server answers
  # "Deprecated field page cannot be combined with filter"), while the plain
  # whole-library query still works by page number. Every page is retried before
  # it is believed and the build fails rather than caching a truncated library.
  local body items count tries
  if [[ $filter_json != "{}" ]]; then
    # Album mode: cursor walk. `type` is left out — it is rejected alongside a
    # filter — and the jq pass below keeps only image mimetypes.
    local cursor="" next_cursor walk=0
    while (( walk < 400 )); do
      walk=$((walk + 1))
      body=$(jq -cn --argjson f "$filter_json" --arg c "$cursor" \
        '{size:1000, filter:$f} + (if $c != "" then {cursor:$c} else {} end)')

      tries=0
      while :; do
        tries=$((tries + 1))
        page_json=$(api_post /api/search/metadata "$body") || page_json=""
        [[ -n $page_json ]] || page_json='{}'
        items=$(jq -er '.assets.items | length' <<<"$page_json" 2>/dev/null) || items=-1
        next_cursor=$(jq -r '.assets.nextCursor // empty' <<<"$page_json" 2>/dev/null) || next_cursor=""
        (( items >= 0 )) && break
        (( tries >= 3 )) && die "album page $walk failed after $tries attempts"
        sleep $(( tries * 2 ))
      done

      (( items == 0 )) && break
      jq -c '.assets.items[] | {id, w: .width, h: .height, mime: .originalMimeType,
             type, date: .fileCreatedAt, name: .originalFileName}' <<<"$page_json" >> "$tmp_raw"
      [[ -z $next_cursor ]] && break
      cursor=$next_cursor
    done
    (( walk >= 400 )) && note "warning: manifest stopped at the 400 page cap"
  else
    # Whole library: numbered pages, server-side IMAGE filter.
    local page=1
    while (( page <= 400 )); do
      body=$(jq -cn --argjson p "$page" '{size:1000, page:$p, type:"IMAGE"}')

      tries=0
      while :; do
        tries=$((tries + 1))
        page_json=$(api_post /api/search/metadata "$body") || page_json=""
        [[ -n $page_json ]] || page_json='{}'
        count=$(jq -er '.assets.count' <<<"$page_json" 2>/dev/null) || count=-1
        items=$(jq -er '.assets.items | length' <<<"$page_json" 2>/dev/null) || items=-1
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
      # last page silently dropped fifteen thousand photos.
      page=$((page + 1))
    done
    (( page > 400 )) && note "warning: manifest stopped at the 400 page cap"
  fi

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

  # Which photos the manifest should hold, so an edit to the source block
  # rebuilds now instead of after refresh_minutes.
  local sig age
  # The manifest is only valid for this origin and this selection.
  sig=$(printf '%s\n%s\n' "$ORIGIN" "$(jq -Sc '.config.source' <<<"$SNAP")" |
        sha256sum | cut -d' ' -f1)

  if (( ! force )) && [[ -s $MANIFEST && -s $MANIFEST_STAMP ]]; then
    age=$(( $(date +%s) - $(cat "$MANIFEST_STAMP") ))
    if (( age < REFRESH_MIN * 60 )) && [[ $(cat "$MANIFEST_SRC" 2>/dev/null) == "$sig" ]]; then
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
  printf '%s\n' "$sig" > "$MANIFEST_SRC"
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

# Caption data for one asset: the photo's own date and where it was taken.
# Cached beside the image so a repeat visit costs nothing.
caption_json() {
  local dest=$1 id=$2 cap="${1%.*}.caption.json"
  if [[ ! -s $cap ]]; then
    api_get "/api/assets/$id" 2>/dev/null |
      jq -c '{date: (.fileCreatedAt // .localDateTime // ""),
              place: ([.exifInfo.city, .exifInfo.state, .exifInfo.country]
                      | map(select(. != null and . != "")) | join(", "))}' > "$cap" 2>/dev/null || true
    [[ -s $cap ]] || printf '{"date":"","place":""}\n' > "$cap"
  fi
  cat "$cap"
}

cmd_fetch() {
  local id=${ARG:-}
  is_uuid "$id" || die "fetch needs a UUID asset id, got: $id"

  local existing
  existing=$(find "$IMG_DIR" -maxdepth 1 -name "$id.*" -print -quit)
  if [[ -n $existing && -s $existing ]]; then
    touch "$existing"   # LRU: usage is recency
    printf '%s\n%s\n' "$existing" "$(caption_json "$existing" "$id")"
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
  printf '%s\n%s\n' "$dest" "$(caption_json "$dest" "$id")"
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
