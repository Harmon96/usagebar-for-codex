#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
build_directory="${project_directory}/.build/release"
app_directory="${project_directory}/dist/CodexUsageMenuBar.app"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/usagebar-build.XXXXXX")"
staged_app_directory="${temporary_directory}/CodexUsageMenuBar.app"

cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT

cd "${project_directory}"
swift build --configuration release

mkdir -p "${staged_app_directory}/Contents/MacOS"
cp "${build_directory}/CodexUsageMenuBar" "${staged_app_directory}/Contents/MacOS/CodexUsageMenuBar"
cp "${project_directory}/Resources/Info.plist" "${staged_app_directory}/Contents/Info.plist"

plutil -lint "${staged_app_directory}/Contents/Info.plist" >/dev/null
codesign --force --sign - "${staged_app_directory}"
codesign --verify --deep --strict "${staged_app_directory}"

mkdir -p "${project_directory}/dist"
if [[ "${app_directory}" != "${project_directory}/dist/CodexUsageMenuBar.app" ]]; then
  print -u2 "Refusing to replace unexpected app path: ${app_directory}"
  exit 1
fi
rm -rf "${app_directory}"
mv "${staged_app_directory}" "${app_directory}"

printf 'Built %s\n' "${app_directory}"
