#!/bin/bash
# autopif_linux.sh
# Adapted from autopif4.sh by osm0sis @ xda-developers
# Linux desktop adaptation: no root/busybox/Android deps required.
# Outputs:
#   pif.prop  — always written (Canary build properties)
#   pif.json  — written only if pif.prop is new or changed

# No set -e / pipefail — we handle errors explicitly per-command

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
item() { echo -e "\n- $*"; }
warn() { echo -e "\nWarning: $*!"; }
die()  { echo -e "\nError: $*!"; exit 1; }

# --------------------------------------------------------------------------- #
# Dependency check
# --------------------------------------------------------------------------- #
for cmd in wget curl date grep sed tac wc; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required tool not found: $cmd"
done

# --------------------------------------------------------------------------- #
# Working directory — same folder as the script
# --------------------------------------------------------------------------- #
DIR="$(dirname "$(readlink -f "$0")")"
cd "$DIR"

TMPDIR="$DIR/.autopif_tmp"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

# --------------------------------------------------------------------------- #
# Step 1 — Fetch device list from Android Developers
# --------------------------------------------------------------------------- #
item "Crawling Android Developers for latest Pixel Beta device list ..."

wget -q -O "$TMPDIR/PIXEL_VERSIONS_HTML" \
  "https://developer.android.com/about/versions" \
  || die "Failed to fetch Android versions page"

LATEST_URL="$(grep -o 'https://developer.android.com/about/versions/.*[0-9]"' \
  "$TMPDIR/PIXEL_VERSIONS_HTML" | sort -ru | cut -d'"' -f1 | head -n1)"
[ -n "$LATEST_URL" ] || die "Could not determine latest Android version URL"

wget -q -O "$TMPDIR/PIXEL_LATEST_HTML" "$LATEST_URL" \
  || die "Failed to fetch latest Android version page"

QPR_PATH="$(grep -o 'href=".*download.*"' "$TMPDIR/PIXEL_LATEST_HTML" \
  | grep 'qpr' | cut -d'"' -f2 | head -n1)"
[ -n "$QPR_PATH" ] || die "Could not find QPR download link"

wget -q -O "$TMPDIR/PIXEL_FI_HTML" \
  "https://developer.android.com${QPR_PATH}" \
  || die "Failed to fetch factory image page"

ALL_MODEL_LIST="$(grep -A1 'tr id=' "$TMPDIR/PIXEL_FI_HTML" \
  | grep 'td' | sed 's;.*<td>\(.*\)</td>.*;\1;')"
ALL_PRODUCT_LIST="$(grep 'tr id=' "$TMPDIR/PIXEL_FI_HTML" \
  | sed 's;.*<tr id="\(.*\)">.*;\1_beta;')"

# --------------------------------------------------------------------------- #
# Step 2 — Filter: Pixel 9 / Pixel 10 only, no A-series
# --------------------------------------------------------------------------- #
item "Filtering for Pixel 9 / Pixel 10 (non-A-series) devices ..."

FILTERED_MODELS=""
FILTERED_PRODUCTS=""

total_lines="$(echo "$ALL_MODEL_LIST" | wc -l)"
i=1
while [ "$i" -le "$total_lines" ]; do
  model="$(echo "$ALL_MODEL_LIST"   | sed -n "${i}p")"
  product="$(echo "$ALL_PRODUCT_LIST" | sed -n "${i}p")"

  if echo "$model" | grep -qE '^Pixel (9|10)( |$)' && \
     ! echo "$model" | grep -qiE '^Pixel (9|10)a'; then
    FILTERED_MODELS="${FILTERED_MODELS}${model}"$'\n'
    FILTERED_PRODUCTS="${FILTERED_PRODUCTS}${product}"$'\n'
  fi
  i=$((i + 1))
done

# Strip trailing blank lines
FILTERED_MODELS="$(printf '%s' "$FILTERED_MODELS" | sed '/^[[:space:]]*$/d')"
FILTERED_PRODUCTS="$(printf '%s' "$FILTERED_PRODUCTS" | sed '/^[[:space:]]*$/d')"

[ -n "$FILTERED_MODELS" ] || die "No Pixel 9/10 (non-A) devices found in the list"

echo "Available devices:"
echo "$FILTERED_MODELS"

# --------------------------------------------------------------------------- #
# Step 3 — Pick a random device
# --------------------------------------------------------------------------- #
item "Selecting random Pixel 9 / Pixel 10 device ..."

list_count="$(echo "$FILTERED_MODELS" | wc -l)"
list_rand=$(( (RANDOM % list_count) + 1 ))

MODEL="$(echo "$FILTERED_MODELS"    | sed -n "${list_rand}p")"
PRODUCT="$(echo "$FILTERED_PRODUCTS" | sed -n "${list_rand}p")"
DEVICE="$(echo "$PRODUCT" | sed 's/_beta//')"

echo "$MODEL ($PRODUCT)"

# --------------------------------------------------------------------------- #
# Step 4 — Fetch Canary build from Android Flash Tool
# --------------------------------------------------------------------------- #
item "Crawling Android Flash Tool for latest Pixel Canary build info ..."

wget -q -O "$TMPDIR/PIXEL_FLASH_HTML" "https://flash.android.com/" \
  || die "Failed to fetch flash.android.com"

API_KEY="$(grep -o '<body data-client-config=[^>]*' "$TMPDIR/PIXEL_FLASH_HTML" \
  | cut -d';' -f2 | cut -d'&' -f1)"
[ -n "$API_KEY" ] || die "Could not extract API key from flash.android.com"

wget -q -O "$TMPDIR/PIXEL_STATION_JSON" \
  --header "Referer: https://flash.android.com" \
  "https://content-flashstation-pa.googleapis.com/v1/builds?product=${PRODUCT}&key=${API_KEY}" \
  || die "Failed to fetch build list from Flash Station"

# tac reverses so grep -m1 finds the latest canary entry
tac "$TMPDIR/PIXEL_STATION_JSON" \
  | grep -m1 -A13 '"canary": true' > "$TMPDIR/PIXEL_CANARY_JSON"

[ -s "$TMPDIR/PIXEL_CANARY_JSON" ] \
  || die "No Canary build found for $PRODUCT — try re-running to get a different device"

ID="$(grep 'releaseCandidateName' "$TMPDIR/PIXEL_CANARY_JSON" | cut -d'"' -f4)"
INCREMENTAL="$(grep 'buildId' "$TMPDIR/PIXEL_CANARY_JSON" | cut -d'"' -f4)"
[ -n "$ID" ]          || die "Failed to extract releaseCandidateName from JSON"
[ -n "$INCREMENTAL" ] || die "Failed to extract buildId from JSON"

echo "Android $(grep 'releaseTrackVersionName' "$TMPDIR/PIXEL_CANARY_JSON" | cut -d'"' -f4)"

# --------------------------------------------------------------------------- #
# Step 5 — Release date from factory image HTTP headers
# --------------------------------------------------------------------------- #
FI="$(grep 'factoryImageDownloadUrl' "$TMPDIR/PIXEL_CANARY_JSON" | cut -d'"' -f4)"

CANARY_REL_DATE="Unknown"
CANARY_EXP_DATE="Unknown"

if [ -n "$FI" ]; then
  # curl -sI sends a HEAD request; -L follows redirects; output goes to file
  curl -sI -L --max-time 15 "$FI" > "$TMPDIR/PIXEL_ZIP_HEADERS" 2>/dev/null

  if grep -qi 'Last-Modified' "$TMPDIR/PIXEL_ZIP_HEADERS"; then
    LM="$(grep -i 'Last-Modified' "$TMPDIR/PIXEL_ZIP_HEADERS" \
          | head -n1 | sed 's/[Ll]ast-[Mm]odified:[[:space:]]*//' | tr -d '\r')"
    CANARY_REL_DATE="$(date -d "$LM" '+%Y-%m-%d' 2>/dev/null)" || CANARY_REL_DATE="Unknown"
    if [ "$CANARY_REL_DATE" != "Unknown" ]; then
      CANARY_EXP_DATE="$(date -d "$CANARY_REL_DATE + 42 days" '+%Y-%m-%d' 2>/dev/null)" \
        || CANARY_EXP_DATE="Unknown"
    fi
  fi
fi

if [ "$CANARY_REL_DATE" = "Unknown" ]; then
  warn "Failed to determine Release Date from HTTP headers"
else
  echo "Canary Released:  $CANARY_REL_DATE"
  echo "Estimated Expiry: $CANARY_EXP_DATE"
fi

# --------------------------------------------------------------------------- #
# Step 6 — Security patch level from Pixel Update Bulletins
# --------------------------------------------------------------------------- #
item "Crawling Pixel Update Bulletins for corresponding security patch level ..."

CANARY_ID="$(grep '"id"' "$TMPDIR/PIXEL_CANARY_JSON" \
  | sed -e 's;.*canary-\(.*\)".*;\1;' -e 's;^\(.\{4\}\);\1-;')"
[ -n "$CANARY_ID" ] || die "Failed to extract canary ID from JSON"

wget -q -O "$TMPDIR/PIXEL_SECBULL_HTML" \
  "https://source.android.com/docs/security/bulletin/pixel" \
  || die "Failed to fetch Pixel Security Bulletin page"

SECURITY_PATCH="$(grep "<td>$CANARY_ID" "$TMPDIR/PIXEL_SECBULL_HTML" \
  | sed 's;.*<td>\(.*\)</td>;\1;' | head -n1)"

if [ -z "$SECURITY_PATCH" ]; then
  warn "Could not find exact security patch level; assuming ${CANARY_ID}-05"
  SECURITY_PATCH="${CANARY_ID}-05"
fi
echo "$SECURITY_PATCH"

# --------------------------------------------------------------------------- #
# Step 7 — Write pif.prop, detect changes
# --------------------------------------------------------------------------- #
item "Dumping values to pif.prop ..."

FINGERPRINT="google/${PRODUCT}/${DEVICE}:CANARY/${ID}/${INCREMENTAL}:user/release-keys"

NEW_PROP="MANUFACTURER=Google
MODEL=$MODEL
FINGERPRINT=$FINGERPRINT
PRODUCT=$PRODUCT
DEVICE=$DEVICE
SECURITY_PATCH=$SECURITY_PATCH
DEVICE_INITIAL_SDK_INT=32"

CHANGED=0
if [ ! -f "$DIR/pif.prop" ]; then
  CHANGED=1
  echo "(pif.prop does not exist — will create)"
else
  OLD_PROP="$(cat "$DIR/pif.prop")"
  if [ "$OLD_PROP" != "$NEW_PROP" ]; then
    CHANGED=1
    echo "(pif.prop content changed)"
  else
    echo "(pif.prop unchanged)"
  fi
fi

printf '%s\n' "$NEW_PROP" | tee "$DIR/pif.prop"

# --------------------------------------------------------------------------- #
# Step 8 — Write pif.json only when changed
# --------------------------------------------------------------------------- #
if [ "$CHANGED" -eq 1 ]; then
  item "Writing pif.json (new or updated fingerprint) ..."
  TODAY="$(date '+%Y%m%d')"
  printf '{\n  "VERSION": "%s",\n  "FINGERPRINT": "%s"\n}\n' \
    "$TODAY" "$FINGERPRINT" | tee "$DIR/pif.json"
else
  item "pif.json not updated (no changes detected)."
fi

echo -e "\nDone."
