#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Android TV APK'sını masaüstü uygulamalarına gömülecek adla dist/tv-app altına kopyalar:
# couchsubs-androidtv_<sürüm>.apk (sürüm tv-android/app/build.gradle'daki versionName).
# Kullanım: bundle-android-apk.sh <apk>
set -e
# Resolve the input against the caller's cwd before switching to the repository.
[ -f "$1" ] || { echo "APK yok: $1"; exit 1; }
APK="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
cd "$(dirname "$0")/.."
VERSION=$(sed -n "s/.*versionName '\([0-9.]*\)'.*/\1/p" tv-android/app/build.gradle | head -1)
mkdir -p dist/tv-app
rm -f dist/tv-app/couchsubs-androidtv_*.apk
cp "$APK" "dist/tv-app/couchsubs-androidtv_$VERSION.apk"
echo "Gömülecek APK: dist/tv-app/couchsubs-androidtv_$VERSION.apk"
