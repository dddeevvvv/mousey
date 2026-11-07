#!/bin/bash
set -uo pipefail
cd "${1:-$(dirname "$0")/..}" || exit 2
failures=0
history=""

fail() {
	echo "FAIL: $1"
	failures=$((failures + 1))
}

if [ -e .git ]; then
	publishable=$(git -c core.quotepath=off ls-files --cached --others --exclude-standard)
	git diff --quiet || fail "the working copy differs from what is staged, so this check cannot vouch for the commit"
	if git rev-parse -q --verify HEAD > /dev/null; then
		other_emails=$(git log --all --format='%ae%n%ce' | sort -u | grep -v '@users\.noreply\.github\.com$')
		[ -z "$other_emails" ] || fail "a commit carries an email that is not a GitHub no-reply address"
		history=$(mktemp)
		git log --all -p --format='%an%n%cn' -- . ':(exclude).gitignore' ':(exclude)scripts/check-public.sh' ':(exclude)scripts/test-check-public.sh' > "$history"
	fi
else
	index=$(mktemp -d)
	git --git-dir="$index" init -q
	publishable=$(git -c core.quotepath=off --git-dir="$index" --work-tree=. ls-files --others --exclude-standard)
	rm -rf "$index"
fi
if [ -z "$publishable" ]; then
	echo "FAIL: no files to check"
	exit 1
fi

for required in LICENSE README.md SECURITY.md; do
	grep -qxF "$required" <<< "$publishable" || fail "missing $required"
done

banned_paths='(^|/)(\.signing|dist|\.build[^/]*|probe|private|\.audit)/|(^|/)(decisions\.tsv|PRODUCT-PLAN\.md|todo\.md|\.env[^/]*)$|\.(keychain|keychain-db|p12|pem|key|cer|mobileprovision)$'
banned=$(grep -E "$banned_paths" <<< "$publishable")
[ -z "$banned" ] || fail "private files would go public: $(tr '\n' ' ' <<< "$banned")"
if [ -n "$history" ]; then
	banned_before=$(git log --all --name-only --format= | sort -u | grep -E "$banned_paths")
	[ -z "$banned_before" ] || fail "private files are in git history: $(tr '\n' ' ' <<< "$banned_before")"
fi

scan=()
holds_these_patterns=()
while IFS= read -r file; do
	if [ -L "$file" ] || [ ! -f "$file" ]; then
		fail "cannot check, not a plain file: $file"
		continue
	fi
	[ "$(wc -c < "$file")" -le 3000000 ] || fail "$file is over 3 MB"
	if [ -s "$file" ] && ! LC_ALL=C grep -qI '' "$file"; then
		case "$file" in
			Assets/AppIcon.icns | docs/images/*.png) ;;
			*) fail "unexpected binary file: $file" ;;
		esac
	else
		case "$file" in
			.gitignore | scripts/check-public.sh | scripts/test-check-public.sh) holds_these_patterns+=("$file") ;;
			*) scan+=("$file") ;;
		esac
	fi
done <<< "$publishable"
[ -z "$history" ] || scan+=("$history")

rule() {
	local name="$1"
	shift
	[ "${#scan[@]}" -gt 0 ] || return 0
	local places
	places=$(LC_ALL=C grep -HnI "$@" -- "${scan[@]}" 2> /dev/null | cut -d: -f1,2 | tr '\n' ' ')
	places=${places//$history/git history}
	[ -z "$places" ] || fail "$name: $places"
}

rule "private key" -E -e '-----BEGIN [A-Z ]*PRIVATE KEY'
rule "certificate" -e 'BEGIN CERTIFICATE'
aws_key='(^|[^A-Z0-9])AKIA[0-9A-Z]{16}($|[^A-Z0-9])'
google_key='(^|[^A-Za-z0-9+/])AIza[0-9A-Za-z_-]{35}($|[^A-Za-z0-9_-])'
rule "access token" -E -e "gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(ant|proj)-[A-Za-z0-9_-]{10,}|sk_live_[A-Za-z0-9]{10,}|$aws_key|$google_key|xox[abprs]-[A-Za-z0-9-]{10,}|tskey-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{10,}"
rule "tailnet detail" -E -e '\.ts\.net|fd7a:115c'
rule "path in a home folder" -E -e '/(Users|home)/[A-Za-z0-9._-]+'
rule "private network address" -E -e '(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})($|[^0-9.])'
rule "mention of a private file" -E -e 'PRODUCT-PLAN|decisions\.tsv|todo\.md|probe/'

scan+=(${holds_these_patterns[@]+"${holds_these_patterns[@]}"})
while IFS= read -r word || [ -n "$word" ]; do
	[ -n "$word" ] || continue
	rule "private word" -w -F -i -e "$word"
	if LC_ALL=C grep -qwFi -e "$word" <<< "$publishable"; then fail "private word in a file name"; fi
done < <(
	id -un
	git config --global user.email
	scutil --get ComputerName 2> /dev/null
	scutil --get LocalHostName 2> /dev/null
	[ ! -f private/words ] || cat private/words
)

[ -z "$history" ] || rm -f "$history"
if [ "$failures" -ne 0 ]; then
	echo "$failures problems"
	exit 1
fi
echo "clean: $(wc -l <<< "$publishable" | tr -d ' ') files checked"
