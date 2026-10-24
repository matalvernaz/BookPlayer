#!/bin/bash
# Checks that a TestFlight build of this fork is a real Release build with real
# config values. Run by .github/workflows/testflight.yml and by the private
# deploy script on the Mac, from the repository root.
#
#   testflight-checks.sh settings <xcconfig>
#     Before archiving. Fails if the Release settings, read with the off-repo
#     xcconfig the archive uses, would make a debug build of the app or of
#     BookPlayerKit (where AppEnvironment compiles). Every build from 05-19 to
#     07-25 was archived as Debug, which turned off the TestFlight-only
#     features and shipped an unoptimised app.
#
#   testflight-checks.sh archive <xcarchive> <bundle-id>
#     After archiving, before export. Fails unless every Info.plist in the app
#     that carries BP_BUNDLE_IDENTIFIER has the real bundle id (the tracked
#     Release.xcconfig says com.replace.me, so a wrong value means the
#     off-repo xcconfig didn't reach that bundle), and unless the app and its
#     watch app are signed with the app group the app opens at launch.
#     BP_API_DOMAIN, BP_REVENUECAT_KEY and BP_SENTRY_DSN are deliberately
#     left as replace.me in the off-repo file: this fork doesn't use the
#     BookPlayer server, in-app purchases or BookPlayer's Sentry.

set -euo pipefail

readonly PROJECT="BookPlayer.xcodeproj"
readonly SETTINGS_TARGETS=(BookPlayer BookPlayerKit)
readonly BUNDLE_ID_KEY="BP_BUNDLE_IDENTIFIER"
readonly APP_GROUPS_KEY="com.apple.security.application-groups"

fail() {
  echo "::error::$1"
  exit 1
}

# Value of one build setting from xcodebuild -showBuildSettings output.
setting_value() {
  awk -F ' = ' -v name="$1" '{ sub(/^ +/, "", $1) } $1 == name { print $2; exit }'
}

check_settings() {
  local xcconfig=$1
  [[ -f "$xcconfig" ]] || fail "missing $xcconfig"

  local target settings conditions optimization
  for target in "${SETTINGS_TARGETS[@]}"; do
    # No package resolution here: it could rewrite Package.resolved, and the
    # settings don't depend on it. -sdk iphoneos reads what the device archive
    # builds, including any [sdk=iphoneos*] conditional values.
    settings=$(xcodebuild -project "$PROJECT" -target "$target" -configuration Release \
      -sdk iphoneos -xcconfig "$xcconfig" -showBuildSettings -disableAutomaticPackageResolution 2>/dev/null) \
      || fail "xcodebuild -showBuildSettings failed for $target"
    conditions=$(setting_value SWIFT_ACTIVE_COMPILATION_CONDITIONS <<<"$settings")
    optimization=$(setting_value SWIFT_OPTIMIZATION_LEVEL <<<"$settings")
    echo "$target: SWIFT_ACTIVE_COMPILATION_CONDITIONS='$conditions' SWIFT_OPTIMIZATION_LEVEL='$optimization'"

    if grep -qw DEBUG <<<"$conditions"; then
      fail "$target would build with DEBUG set"
    fi
    if [[ -z "$optimization" || "$optimization" == "-Onone" ]]; then
      fail "$target would build unoptimised"
    fi
  done
}

check_archive() {
  local archive=$1 bundle_id=$2
  local app
  app=$(find "$archive/Products/Applications" -maxdepth 1 -name '*.app' | head -n 1)
  [[ -n "$app" ]] || fail "no app in $archive"

  # The app's own Info.plist must carry the key; the extensions and the watch
  # app carry it too, and each must match.
  /usr/libexec/PlistBuddy -c "Print :$BUNDLE_ID_KEY" "$app/Info.plist" > /dev/null 2>&1 \
    || fail "${app##*/} has no $BUNDLE_ID_KEY"
  local plist value wrong=0 checked=0
  while IFS= read -r -d '' plist; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$BUNDLE_ID_KEY" "$plist" 2>/dev/null) || continue
    checked=$((checked + 1))
    if [[ "$value" != "$bundle_id" ]]; then
      echo "::error::${plist#"$archive"/}: $BUNDLE_ID_KEY is '$value', expected '$bundle_id'"
      wrong=1
    fi
  done < <(find "$app" -name Info.plist -print0)
  [[ "$wrong" -eq 0 ]] || exit 1
  echo "$BUNDLE_ID_KEY is $bundle_id in all $checked bundles that carry it."

  # The app (and the watch app) open group.<bundle id>.files at launch;
  # CoreDataStack force-unwraps that container.
  local expected="group.${bundle_id}.files"
  local signed entitlements groups
  for signed in "$app" "$app"/Watch/*.app; do
    [[ -d "$signed" ]] || continue
    entitlements=$(mktemp)
    codesign -d --entitlements - --xml "$signed" > "$entitlements" 2>/dev/null || true
    # PlistBuddy prints its errors on stdout, so only keep its output when it worked.
    if groups=$(/usr/libexec/PlistBuddy -c "Print :$APP_GROUPS_KEY" "$entitlements" 2>/dev/null); then
      groups=$(tr -s ' \n' ' ' <<<"$groups")
    else
      groups=""
    fi
    rm -f "$entitlements"
    echo "${signed#"$archive"/}: $APP_GROUPS_KEY = ${groups:-<none>}"
    grep -qw "$expected" <<<"$groups" || fail "${signed##*/} is not signed with $expected"
  done
}

case "${1:-}" in
  settings)
    [[ $# -eq 2 ]] || fail "usage: $0 settings <xcconfig>"
    check_settings "$2"
    ;;
  archive)
    [[ $# -eq 3 ]] || fail "usage: $0 archive <xcarchive> <bundle-id>"
    check_archive "$2" "$3"
    ;;
  *)
    fail "usage: $0 settings <xcconfig> | archive <xcarchive> <bundle-id>"
    ;;
esac
