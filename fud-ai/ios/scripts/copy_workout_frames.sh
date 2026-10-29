#!/bin/sh
# Xcode run-script build phase ("Copy Workout Frames") for the calorietracker target.
#
# Shipping builds do NOT bundle the ~7,000-frame / 1.2 GB workout corpus. Only the
# manifest ships (as the ExerciseVisualManifest asset-catalog data set); frames are
# downloaded on demand by WorkoutFrameStore from the workout-vector CDN. This phase
# therefore does two things, mirroring Android's prepare<Variant>WorkoutVectorAssets:
#
#   Debug   (WORKOUT_VECTORS=sample, the default) copies the small sample pack listed in
#           shared/workout-vectors/sample-pack.txt (12 exercises, 96 frames, ~15 MB) to
#           calorietracker.app/workout-vectors/<name>.png so those exercises animate
#           offline without a CDN. WORKOUT_VECTORS=all copies the whole corpus for local
#           QA only; WORKOUT_VECTORS=none gives release parity.
#   Release (WORKOUT_VECTORS=none, forced) bundles no frames at all. Any other mode is a
#           hard build error, and the phase also fails the build if authored frames
#           (*_v2_*.png) leaked into the bundle by some other route, so the corpus can
#           never end up in an IPA again.
#
# Override with a build setting or environment variable, e.g.
#   xcodebuild -scheme calorietracker -configuration Debug WORKOUT_VECTORS=none ...
#
# Nothing else from shared/workout-vectors (README.md, sample-pack.txt, the manifest
# copy, the legacy SVG pilot) ever reaches the bundle. Sample copies are verified
# against the manifest by name so a stray file cannot sneak in.
#
# Xcode provides CONFIGURATION, SRCROOT, TARGET_BUILD_DIR and
# UNLOCALIZED_RESOURCES_FOLDER_PATH. The calorietracker target sets
# ENABLE_USER_SCRIPT_SANDBOXING = NO: the sandbox only whitelists the declared output
# path itself, not the files created beneath it, so a sandboxed build denies `cp`
# with "file-write-create" and ships an empty workout-vectors/ folder.
set -eu

SOURCE="${WORKOUT_VECTORS_SOURCE:-${SRCROOT}/../shared/workout-vectors}"
BUNDLE="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
DESTINATION="$BUNDLE/workout-vectors"
MANIFEST_NAME="exercise-visual-manifest.json"
SAMPLE_LIST="$SOURCE/sample-pack.txt"
# 875 illustrated exercises x 2 genders x 4 frames (scripts/sync_workout_visual_assets.py).
EXPECTED_FRAME_COUNT="${WORKOUT_VECTORS_EXPECTED_FRAMES:-7000}"

fail() {
    echo "error: workout frames: $*" >&2
    exit 1
}

case "${CONFIGURATION:-Release}" in
    Debug) is_release=0 ;;
    *) is_release=1 ;;
esac

requested="${WORKOUT_VECTORS:-}"
if [ "$is_release" -eq 1 ]; then
    if [ -n "$requested" ] && [ "$requested" != "none" ]; then
        fail "WORKOUT_VECTORS=$requested is not allowed for $CONFIGURATION builds; store binaries must only bundle the manifest"
    fi
    mode=none
else
    mode="${requested:-sample}"
fi
case "$mode" in
    none|sample|all) ;;
    *) fail "unknown WORKOUT_VECTORS mode '$mode' (none|sample|all)" ;;
esac

[ -d "$SOURCE" ] || fail "corpus directory not found: $SOURCE"
[ -f "$SOURCE/$MANIFEST_NAME" ] || fail "manifest not found: $SOURCE/$MANIFEST_NAME"
[ -d "$BUNDLE" ] || fail "bundle resources folder not found: $BUNDLE"

# Every `<name>.png` the manifest's male/female sequences reference, one per line.
manifest_frames=$(grep -o '"[^"]*_v2_[0-9][0-9]*"' "$SOURCE/$MANIFEST_NAME" | tr -d '"' | sort -u)
manifest_count=$(printf '%s\n' "$manifest_frames" | grep -c .)
[ "$manifest_count" -eq "$EXPECTED_FRAME_COUNT" ] \
    || fail "$MANIFEST_NAME names $manifest_count frames, expected $EXPECTED_FRAME_COUNT; run scripts/sync_workout_visual_assets.py"

# Always start from a clean destination so a previous sample/all build can never leak
# into a release-parity build of the same DerivedData.
rm -rf "$DESTINATION"

if [ "$mode" = none ]; then
    # Release guard: no authored frame may be anywhere in the bundle so far, whatever put it
    # there (a stray developer folder picked up by the synchronized group, an old build
    # phase...). Extensions and the Watch app are embedded *after* this phase, so the
    # "Verify Workout Frames" phase (scripts/verify_workout_frames.sh) re-scans the
    # finished bundle, PlugIns and Watch included, as the last step of the build.
    leaked=$(find "$BUNDLE" -name '*_v2_*.png' 2>/dev/null | head -8)
    if [ -n "$leaked" ]; then
        echo "error: workout frames: $CONFIGURATION bundle contains authored workout frames:" >&2
        printf '%s\n' "$leaked" | sed 's/^/    /' >&2
        fail "store binaries must only bundle the manifest (see shared/workout-vectors/README.md)"
    fi
    echo "workout frames ($mode): bundled manifest only (frames come from the CDN at runtime)"
    exit 0
fi

mkdir -p "$DESTINATION"

selected_frames=$(
    if [ "$mode" = all ]; then
        printf '%s\n' "$manifest_frames"
    else
        [ -f "$SAMPLE_LIST" ] || fail "sample list not found: $SAMPLE_LIST"
        sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$SAMPLE_LIST" | grep -v '^$' | sort -u | while IFS= read -r exercise; do
            for gender in male female; do
                for index in 0 1 2 3; do
                    printf '%s\n' "${exercise}_${gender}_v2_${index}"
                done
            done
        done | sort -u
    fi
)
[ -n "$selected_frames" ] || fail "mode $mode selected no frames"

# Every selected frame must be named by the manifest (no orphaned or misspelt frames).
manifest_list=$(mktemp)
selected_list=$(mktemp)
trap 'rm -f "$manifest_list" "$selected_list"' EXIT
printf '%s\n' "$manifest_frames" > "$manifest_list"
printf '%s\n' "$selected_frames" > "$selected_list"
orphans=$(comm -13 "$manifest_list" "$selected_list")
if [ -n "$orphans" ]; then
    echo "error: workout frames: selected frames missing from $MANIFEST_NAME:" >&2
    printf '%s\n' "$orphans" | head -8 | sed 's/^/    /' >&2
    fail "run scripts/sync_workout_visual_assets.py --check"
fi

copied=0
while IFS= read -r frame; do
    [ -n "$frame" ] || continue
    source_file="$SOURCE/$frame.png"
    [ -f "$source_file" ] || fail "frame missing from corpus: $source_file"
    [ -L "$source_file" ] && fail "canonical frames must not be symlinks: $source_file"
    cp -p "$source_file" "$DESTINATION/$frame.png" || fail "copy failed: $source_file"
    copied=$((copied + 1))
done < "$selected_list"

echo "workout frames ($mode): bundled $copied frame(s) into $DESTINATION (${CONFIGURATION} only; release ships the manifest alone)"
