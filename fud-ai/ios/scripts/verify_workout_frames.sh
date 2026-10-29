#!/bin/sh
# Xcode run-script build phase ("Verify Workout Frames") for the calorietracker target.
#
# Runs LAST, after "Embed Foundation Extensions" and "Embed Watch Content", and scans the
# whole assembled calorietracker.app — PlugIns/*.appex and Watch/*.app included — for
# authored workout frames (*_v2_*.png). "Copy Workout Frames" runs before the embed
# phases, so it cannot see resources that an extension or the Watch app packaged; this
# phase closes that gap and is the final guarantee that the ~1.2 GB corpus never reaches
# an IPA (frames are downloaded from the CDN at runtime).
#
#   Debug:  frames are allowed only directly inside calorietracker.app/workout-vectors/
#           (the sample pack that copy_workout_frames.sh placed there); anything
#           elsewhere fails the build.
#   Other:  no *_v2_*.png may exist anywhere in the bundle.
#
# Read-only: nothing is copied or deleted. Xcode provides CONFIGURATION,
# TARGET_BUILD_DIR, WRAPPER_NAME and UNLOCALIZED_RESOURCES_FOLDER_PATH.
set -eu

BUNDLE="${TARGET_BUILD_DIR}/${WRAPPER_NAME:-${UNLOCALIZED_RESOURCES_FOLDER_PATH}}"
SAMPLE_DIRECTORY="$BUNDLE/workout-vectors"

fail() {
    echo "error: workout frames: $*" >&2
    exit 1
}

[ -d "$BUNDLE" ] || fail "app bundle not found: $BUNDLE"

case "${CONFIGURATION:-Release}" in
    Debug)
        leaked=$(find "$BUNDLE" -name '*_v2_*.png' -not -path "$SAMPLE_DIRECTORY/*" 2>/dev/null | head -8)
        allowed="only $SAMPLE_DIRECTORY/ may hold the Debug sample pack"
        ;;
    *)
        leaked=$(find "$BUNDLE" -name '*_v2_*.png' 2>/dev/null | head -8)
        allowed="store binaries must only bundle the manifest"
        ;;
esac

if [ -n "$leaked" ]; then
    echo "error: workout frames: ${CONFIGURATION:-Release} bundle contains authored workout frames outside the allowed location:" >&2
    printf '%s\n' "$leaked" | sed 's/^/    /' >&2
    fail "$allowed (see shared/workout-vectors/README.md)"
fi

total=$(find "$BUNDLE" -name '*_v2_*.png' 2>/dev/null | wc -l | tr -d ' ')
echo "workout frames: verified ${CONFIGURATION:-Release} bundle (PlugIns + Watch included): $total authored frame(s), none outside the allowed location"
