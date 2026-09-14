#
# CocoaPods spec for the mithra_flutter_sdk plugin.
#
# Run `pod lib lint mithra_flutter_sdk.podspec` to validate before publishing.
#
# The Narya iOS SDK is not published as a pod, so this spec vendors the
# prebuilt XCFramework from https://sdk.mithra.com/ios/. `prepare_command`
# downloads the pinned versioned archive, verifies it against the release's
# checksum file, and unpacks it into ios/Frameworks/ (which is gitignored).
#
# Flutter also supports Swift Package Manager for plugins; see
# ios/mithra_flutter_sdk/Package.swift for that path, which resolves the SDK through
# the hosted Swift package instead of a vendored binary.
#
narya_sdk_version = '1.4.0'

Pod::Spec.new do |s|
  s.name             = 'mithra_flutter_sdk'
  s.version          = '1.0.1' # x-release-please-version
  s.summary          = "Mithra's Narya SDK for Flutter."
  s.description      = <<-DESC
  A thin Flutter bridge over the Narya native SDKs for analytics, push
  notifications, in-app messages and the mobile inbox.
                       DESC
  s.homepage         = 'https://mithra.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Mithra' => 'sdk@mithra.com' }
  s.source           = { :path => '.' }
  # Single source of truth, shared with the Swift Package Manager path.
  s.source_files     = 'mithra_flutter_sdk/Sources/mithra_flutter_sdk/**/*.swift'
  s.dependency 'Flutter'
  # Minimum matches the native SDK's Package.swift (.iOS(.v15)).
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  # `prepare_command` only runs for a local (`:path`) pod from CocoaPods 1.9 on.
  # Older versions skip it silently and the build then fails at link time with
  # "no such file Frameworks/MithraAnalytics.xcframework".
  s.cocoapods_version = '>= 1.9'

  s.vendored_frameworks = 'Frameworks/MithraAnalytics.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }

  # Download, verify and unpack the pinned XCFramework.
  #
  # To develop against a local narya-ios checkout instead, drop a prebuilt
  # MithraAnalytics.xcframework into ios/Frameworks/ before `pod install` --
  # the command below is a no-op when the framework is already present. See
  # the README section "Local development against the native SDKs".
  s.prepare_command = <<-CMD
    set -euo pipefail

    VERSION="#{narya_sdk_version}"
    BASE_URL="https://sdk.mithra.com/ios"
    ARCHIVE="MithraAnalytics-${VERSION}.zip"
    DEST="Frameworks"

    if [ -d "${DEST}/MithraAnalytics.xcframework" ]; then
      echo "mithra_flutter_sdk: ${DEST}/MithraAnalytics.xcframework already present; skipping download."
      exit 0
    fi

    WORK="$(mktemp -d)"
    trap 'rm -rf "${WORK}"' EXIT

    echo "mithra_flutter_sdk: downloading ${ARCHIVE}"
    curl --fail --silent --show-error --location \
      "${BASE_URL}/${ARCHIVE}" --output "${WORK}/${ARCHIVE}"
    curl --fail --silent --show-error --location \
      "${BASE_URL}/checksums-${VERSION}.txt" --output "${WORK}/checksums.txt"

    EXPECTED="$(grep -i "${ARCHIVE}" "${WORK}/checksums.txt" \
      | grep -Eo '[0-9a-fA-F]{64}' | head -n 1 || true)"
    if [ -z "${EXPECTED}" ]; then
      echo "mithra_flutter_sdk: no checksum for ${ARCHIVE} in checksums-${VERSION}.txt" >&2
      exit 1
    fi

    ACTUAL="$(shasum -a 256 "${WORK}/${ARCHIVE}" | awk '{print $1}')"
    if [ "${ACTUAL}" != "$(echo "${EXPECTED}" | tr 'A-Z' 'a-z')" ]; then
      echo "mithra_flutter_sdk: checksum mismatch for ${ARCHIVE}" >&2
      echo "  expected ${EXPECTED}" >&2
      echo "  actual   ${ACTUAL}" >&2
      exit 1
    fi

    mkdir -p "${DEST}"
    unzip -q "${WORK}/${ARCHIVE}" -d "${WORK}/unpacked"
    FRAMEWORK="$(find "${WORK}/unpacked" -maxdepth 3 -name 'MithraAnalytics.xcframework' -type d | head -n 1)"
    if [ -z "${FRAMEWORK}" ]; then
      echo "mithra_flutter_sdk: MithraAnalytics.xcframework not found inside ${ARCHIVE}" >&2
      exit 1
    fi
    rm -rf "${DEST}/MithraAnalytics.xcframework"
    cp -R "${FRAMEWORK}" "${DEST}/MithraAnalytics.xcframework"
    echo "mithra_flutter_sdk: installed MithraAnalytics.xcframework ${VERSION}"
  CMD
end
