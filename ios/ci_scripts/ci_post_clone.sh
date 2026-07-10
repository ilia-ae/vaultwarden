#!/bin/sh
set -e

echo "=== ci_post_clone.sh ==="

# Install Flutter (latest stable)
echo "Installing Flutter (latest stable)..."
git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$HOME/flutter"
export PATH="$HOME/flutter/bin:$PATH"

flutter --version
flutter precache --ios

# Generate plugin registrant and get dependencies
echo "Running flutter pub get..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
flutter pub get

# Re-sync the generated plugin registrant into the renamed target's copy.
# `flutter pub get` regenerates ios/Runner/GeneratedPluginRegistrant.{m,h},
# but the VaultApprover target compiles ios/VaultApprover/GeneratedPluginRegistrant.
# Without this the two drift and newly-added plugins (e.g. Firebase) fail to
# register at runtime (PlatformException channel-error → app hangs on splash).
echo "Syncing GeneratedPluginRegistrant into VaultApprover target..."
cp "$CI_PRIMARY_REPOSITORY_PATH/ios/Runner/GeneratedPluginRegistrant.m" \
   "$CI_PRIMARY_REPOSITORY_PATH/ios/VaultApprover/GeneratedPluginRegistrant.m"
cp "$CI_PRIMARY_REPOSITORY_PATH/ios/Runner/GeneratedPluginRegistrant.h" \
   "$CI_PRIMARY_REPOSITORY_PATH/ios/VaultApprover/GeneratedPluginRegistrant.h"

# CocoaPods (must run BEFORE flutter build to fix bridging header scan).
# --repo-update so a fresh CI spec cache can resolve recent pods (Firebase 12.x).
echo "Installing CocoaPods dependencies..."
cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
pod install --repo-update

# Flutter build
echo "Running flutter build ios..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
flutter build ios --release --no-codesign

echo "=== ci_post_clone.sh complete ==="
