#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 SOURCE=DESTINATION [...]" >&2
  exit 2
fi

for mapping in "$@"; do
  source_path=${mapping%%=*}
  destination_path=${mapping#*=}

  if [ "$source_path" = "$mapping" ]; then
    echo "Invalid mapping '$mapping'; expected SOURCE=DESTINATION." >&2
    exit 2
  fi

  case "$destination_path" in
    .hosted-agent-build/*) ;;
    *)
      echo "Refusing to replace unsafe destination '$destination_path'." >&2
      exit 2
      ;;
  esac

  if [ ! -d "$source_path" ]; then
    echo "Hosted-agent source directory not found: $source_path" >&2
    exit 1
  fi

  mkdir -p "$destination_path"
  find "$destination_path" \
    ! -path "$destination_path" \
    ! -path "$destination_path/.gitignore" \
    -prune -exec rm -rf -- {} +
  cp -R "$source_path"/. "$destination_path"/
  find "$destination_path" -type d \( \
    -name .venv -o \
    -name __pycache__ -o \
    -name bin -o \
    -name obj \
  \) -prune -exec rm -rf -- {} +
  find "$destination_path" -type f \( -name '*.pyc' -o -name '*.pyo' \) -exec rm -f -- {} +
  echo "Staged $source_path -> $destination_path"
done
