#!/bin/bash
# Everything that runs with no extra permission. Binds loopback only, posts nothing, opens no window.
set -uo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-.build}"
mkdir -p "$SCRATCH"
RECORDING="${1:-Tests/Fixtures/trackpad-recording.json}"
APP="dist/Mousey.app/Contents/MacOS/Mousey"
failures=0
summary=()

step() {
	local name="$1"
	shift
	echo "== $name"
	if "$@"; then
		summary+=("ok      $name")
	else
		summary+=("FAILED  $name")
		failures=$((failures + 1))
	fi
}

tests() {
	swift test --scratch-path "$SCRATCH" > "$SCRATCH/verify-tests.log" 2>&1
	local rc=$?
	grep -E "Executed [0-9]+ tests" "$SCRATCH/verify-tests.log" | tail -1
	[ $rc -eq 0 ] || grep -E "error:|failed" "$SCRATCH/verify-tests.log" | head -20
	return $rc
}

helper_path() {
	local helper="$PWD/dist/Mousey.app/Contents/MacOS/MouseyHelper"
	[ "$("$helper" --self-path)" = "$helper" ]
}

# Under the hardened runtime, as a release runs. The test modes exist only in a debug build.
selftest() {
	swift build --scratch-path "$SCRATCH" > "$SCRATCH/verify-build.log" 2>&1 || {
		tail -20 "$SCRATCH/verify-build.log"
		return 1
	}
	local folder code
	folder=$(mktemp -d)
	cp "$SCRATCH/debug/Mousey" "$folder/Mousey"
	codesign -f -s - --options runtime "$folder/Mousey" 2> /dev/null
	"$folder/Mousey" --selftest "$RECORDING"
	code=$?
	rm -rf "$folder"
	return $code
}

release_has_no_test_modes() {
	if LC_ALL=C grep -qa -e '--selftest' -e '--render-screens' "$APP"; then
		echo "the release app holds a test mode"
		return 1
	fi
	"$APP" --selftest-dock /nonexistent > /dev/null 2>&1
	[ $? -eq 64 ]
}

release_is_hardened() {
	local signature
	signature=$(codesign -dv "$APP" 2>&1)
	[[ "$signature" == *flags=*runtime* ]]
}

release_refuses_injected_code() {
	local folder code=0
	folder=$(mktemp -d)
	printf '#include <stdio.h>\n__attribute__((constructor)) static void planted(void) { fclose(fopen("%s/ran", "w")); }\n' "$folder" > "$folder/planted.c"
	clang -dynamiclib -arch arm64 -arch x86_64 -o "$folder/planted.dylib" "$folder/planted.c" || return 1
	cp "$APP" "$folder/control"
	codesign -f -s - "$folder/control" 2> /dev/null
	DYLD_INSERT_LIBRARIES="$folder/planted.dylib" "$folder/control" --nope > /dev/null 2>&1
	if [ ! -e "$folder/ran" ]; then
		echo "the unhardened control did not run the planted code, so this check proves nothing"
		code=1
	fi
	rm -f "$folder/ran"
	DYLD_INSERT_LIBRARIES="$folder/planted.dylib" "$APP" --nope > /dev/null 2>&1
	if [ -e "$folder/ran" ]; then
		echo "the release app ran injected code"
		code=1
	fi
	rm -rf "$folder"
	return $code
}

step "swift test" tests
step "build app" env SCRATCH="$SCRATCH" scripts/build-app.sh
step "selftest $RECORDING" selftest
step "release app has no test modes" release_has_no_test_modes
step "release app is hardened" release_is_hardened
step "release app refuses injected code" release_refuses_injected_code
step "helper installs its own file" helper_path
step "leak check catches planted leaks" scripts/test-check-public.sh
# The word list names one maintainer's private details, and on another Mac a name like "Mac mini" would match the docs.
if [ -f private/words ]; then
	step "files that would go public are clean" scripts/check-public.sh
fi

echo
echo "== summary"
printf '%s\n' "${summary[@]}"
exit $failures
