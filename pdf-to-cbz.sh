#!/usr/bin/env bash

# === Script Configuration and Safety ===
set -euo pipefail
set -x
trap 'echo "💥 Script failed on line $LINENO"; exit 1' ERR

DPI=150
TMPDIR=$(mktemp -d)
trap '[[ -d "$TMPDIR" ]] && rm -rf "$TMPDIR"' EXIT
echo "🛠️  Temp dir: $TMPDIR"

for cmd in pdftoppm zip pdfinfo identify; do
  command -v "$cmd" >/dev/null || { echo "❌ Missing $cmd (from poppler-utils or ImageMagick?)"; exit 1; }
done

sanitize() {
  echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

trim() {
  echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

infer_series_and_number() {
  local filename="$1"
  if [[ "$filename" =~ ^(.*)[[:space:]]-[[:space:]]([0-9]+)$ ]]; then
    SERIES="${BASH_REMATCH[1]}"
    NUMBER=$(echo "${BASH_REMATCH[2]}" | sed 's/^0*//')
  else
    SERIES="$filename"
    NUMBER=""
  fi
}

process_pdf() {
  local pdf="$1"
  local pdf_full_path
  pdf_full_path="$(cd "$(dirname "$pdf")" && pwd)/$(basename "$pdf")"

  local basedir base work
  basedir="$(dirname "$pdf_full_path")"
  base="$(basename "${pdf_full_path%.*}")"
  work="$TMPDIR/$base"
  mkdir -p "$work"

  echo "➡️  Processing: $base"

  pdftoppm -jpeg -jpegopt quality=70 -progress -r "$DPI" "$pdf_full_path" "$work/page" || return 1

  if ! ls "$work"/page-*.jpg >/dev/null 2>&1; then
    echo "❌ No images were created by pdftoppm for $pdf"
    return 1
  fi

  local n=1
  for img in "$work"/page-*.jpg; do
    mv "$img" "$work/$(printf "%04d.jpg" "$n")"
    ((n++))
  done

  local title author creator pages year summary
  local pdf_metadata
  pdf_metadata=$(pdfinfo "$pdf_full_path")

  title=$(trim "$(echo "$pdf_metadata" | grep '^Title:' | sed 's/^Title:[[:space:]]*//')")
  author=$(trim "$(echo "$pdf_metadata" | grep '^Author:' | sed 's/^Author:[[:space:]]*//')")
  creator=$(trim "$(echo "$pdf_metadata" | grep '^Creator:' | sed 's/^Creator:[[:space:]]*//')")
  pages=$(trim "$(echo "$pdf_metadata" | grep '^Pages:' | sed 's/^Pages:[[:space:]]*//')")
  year=$(echo "$pdf_metadata" | awk -F: '/^(CreationDate|ModDate):/ { if (match($0, /[0-9]{4}/)) { print substr($0, RSTART, RLENGTH); exit } }')
  year="${year:-1900}"
  summary=$(trim "$(echo "$pdf_metadata" | grep '^Subject:' | sed 's/^Subject:[[:space:]]*//')")
  infer_series_and_number "$base"

  title=$(sanitize "${title:-$base}")
  author=$(sanitize "${author:-Unknown}")
  creator=$(sanitize "${creator:-Unknown}")
  series=$(sanitize "${SERIES:-$base}")
  number=$(sanitize "${NUMBER}")
  summary=$(sanitize "${summary:-Auto-generated from PDF by script.}")
  genre=$(sanitize "General")
  tags=$(sanitize "PDF,Comic")
  country="France"
  scaninfo="Converted from PDF with script"
  manga="No"
  blackwhite="false"
  readingdir="LeftToRight"

  {
  cat <<EOF
<?xml version='1.0' encoding='utf-8'?>
<ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Series>$series</Series>
  <Number>$number</Number>
  <Title>$title</Title>
  <Volume>$number</Volume>
  <Genre>$genre</Genre>
  <Summary>$summary</Summary>
  <Year>$year</Year>
  <LanguageISO>French</LanguageISO>
  <Manga>$manga</Manga>
  <Tags>$tags</Tags>
  <PageCount>${pages:-}</PageCount>
  <Writer>$author</Writer>
  <Pages>
EOF

  shopt -s nullglob
  i=0
  for img in "$work"/*.jpg; do
    file_size=$(stat -f%z "$img" 2>/dev/null || stat -c%s "$img")
    dims=$(identify -format "%w %h" "$img" 2>/dev/null || echo "0 0")
    width=$(echo "$dims" | cut -d' ' -f1)
    height=$(echo "$dims" | cut -d' ' -f2)

    if [[ "$i" -eq 0 ]]; then
      echo "    <Page DoublePage=\"False\" Image=\"$i\" ImageHeight=\"$height\" ImageSize=\"$file_size\" ImageWidth=\"$width\" Type=\"FrontCover\" />"
    else
      echo "    <Page DoublePage=\"False\" Image=\"$i\" ImageHeight=\"$height\" ImageSize=\"$file_size\" ImageWidth=\"$width\" />"
    fi
    ((i++))
  done
  shopt -u nullglob

  cat <<EOF
  </Pages>
</ComicInfo>
EOF
  } > "$work/ComicInfo.xml"

  local cbz_out
  cbz_out="$(cd "$basedir" && pwd)/$base.cbz"
  echo "📦 Creating CBZ: $cbz_out"

  zip -jX "$cbz_out" "$work"/*.jpg "$work"/ComicInfo.xml || {
    echo "❌ zip failed"
    return 1
  }

  [[ -f "$cbz_out" ]] && echo "✅ Created: $cbz_out" || echo "❌ CBZ not created"
}

if [[ "$#" -eq 0 ]]; then
  echo "Usage: $0 file1.pdf [file2.pdf ...]"
  exit 1
fi

for pdf in "$@"; do
  if [[ -f "$pdf" && "$pdf" == *.pdf ]]; then
    process_pdf "$pdf"
  else
    echo "⚠️  Skipping: $pdf is not a valid file."
  fi
done
