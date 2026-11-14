#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
configuration="${1:-release}"
output_dir="$project_dir/dist"
app_dir="$output_dir/ThunderLink.app"

# Pin the local certificate once so future releases keep the same identity.
# Refuse to silently switch existing installations to ad-hoc signing.
identity_file="$HOME/Library/Application Support/ThunderLink/Signing/identity.sha1"
if [[ ! -r "$identity_file" ]]; then
  print -u2 "找不到 ThunderLink 签名证书的指纹文件：$identity_file"
  exit 1
fi
signer="$(<"$identity_file")"
if [[ ${#signer} != 40 || "$signer" == *[^0-9A-Fa-f]* ]]; then
  print -u2 "签名证书指纹格式不正确。"
  exit 1
fi

cd "$project_dir"
swift build -j 2 -c "$configuration"
binary_dir="$(swift build -j 2 -c "$configuration" --show-bin-path)"

/bin/mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.package.XXXXXX")"
trap '/bin/rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/ThunderLink.app"
/bin/mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
/bin/cp "$binary_dir/ThunderLink" "$staged_app/Contents/MacOS/ThunderLink"
/bin/cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"
/bin/cp "$project_dir/Resources/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --timestamp=none --sign "$signer" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"
/usr/bin/codesign --verify --strict -R="identifier \"com.sunny.thunderlink\" and certificate leaf = H\"$signer\"" "$staged_app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$staging_dir/ThunderLink.zip"
/usr/bin/zip -q -j "$staging_dir/ThunderLink.zip" "$project_dir/LICENSE"

# Preserve the last package until both the signed app and archive are complete.
if [[ -e "$app_dir" ]]; then
  /bin/mv "$app_dir" "$staging_dir/previous.app"
fi
/bin/mv "$staged_app" "$app_dir"
/bin/mv -f "$staging_dir/ThunderLink.zip" "$output_dir/ThunderLink.zip"

echo "$app_dir"
