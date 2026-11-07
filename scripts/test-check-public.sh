#!/bin/bash
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-public.sh"
failures=0
commit='git -c user.name=t -c user.email=t@users.noreply.github.com -c commit.gpgsign=false commit -qm x'

folder() {
	local d
	d=$(mktemp -d)
	printf 'licence\n' > "$d/LICENSE"
	printf 'readme\n' > "$d/README.md"
	printf 'security\n' > "$d/SECURITY.md"
	printf 'private/\n' > "$d/.gitignore"
	echo "$d"
}

catches() {
	local d output code
	d=$(folder)
	(cd "$d" && eval "$2")
	output=$("$check" "$d" 2>&1)
	code=$?
	if [ "$code" -ne 0 ] && grep -qF "$1" <<< "$output"; then
		echo "caught: $1 ($2)"
	else
		echo "MISSED: $1 ($2)"
		failures=$((failures + 1))
	fi
	rm -rf "$d"
}

passes() {
	local d
	d=$(folder)
	(cd "$d" && eval "$1")
	if "$check" "$d" > /dev/null 2>&1; then
		echo "passed: $1"
	else
		echo "WRONGLY FAILED: $1"
		failures=$((failures + 1))
	fi
	rm -rf "$d"
}

empty=$(mktemp -d)
output=$("$check" "$empty" 2>&1)
code=$?
if [ "$code" -ne 0 ] && grep -qF "no files to check" <<< "$output"; then echo "caught: an empty folder"; else
	echo "MISSED: an empty folder"
	failures=$((failures + 1))
fi
rm -rf "$empty"

passes 'true'
passes 'printf "macOS 10.15.7, test address 192.0.2.1\n" > a.txt'
passes 'printf "AAAAAKIA%s\n" AAAAAAAAAAAAAAAAAAAA > a.txt'
passes 'printf "x%sy\n" "$(id -un)" > a.txt'
passes 'mkdir private && printf "secret\n" > private/words'
passes "git init -q && git add -A && $commit"

catches 'missing LICENSE' 'rm LICENSE'
catches 'private files would go public' 'mkdir .signing && printf x > .signing/password'
catches 'private files would go public' 'mkdir dist && printf x > dist/Mousey.zip'
catches 'private files would go public' 'mkdir probe && printf x > probe/recording.json'
catches 'private files would go public' 'printf x > decisions.tsv'
catches 'private files would go public' 'printf x > id.p12'
catches 'private files would go public' 'printf x > signing.keychain-db'
catches 'private files would go public' 'printf "x\n" > .gitignore && mkdir private && printf x > private/notes'
catches 'cannot check, not a plain file' 'ln -s /nonexistent/target link'
catches 'cannot check, not a plain file' 'ln -s . folder-link'
catches 'unexpected binary file' 'printf "\000\001\002\003" > blob.dat'
catches 'over 3 MB' 'head -c 3500000 /dev/zero | tr "\000" a > big.txt'
catches 'private key' 'printf -- "-----BEGIN RSA PRIVATE %s-----\n" KEY > a.txt'
catches 'certificate' 'printf -- "-----BEGIN %s-----\n" CERTIFICATE > a.txt'
catches 'access token' 'printf "gh%s\n" p_abcdefghijklmnopqrstuvwxyz > a.txt'
catches 'access token' 'printf "key=AKIA%s\n" ABCDEFGHIJKLMNOP > a.txt'
catches 'access token' 'printf "key=AIza%s\n" abcdefghijklmnopqrstuvwxyz012345678 > a.txt'
catches 'access token' 'printf "tskey-%s\n" auth-abcdefghijklmn > a.txt'
catches 'access token' 'printf "hf_%s\n" abcdefghijklmnopqrstuvwxyz > a.txt'
catches 'access token' 'printf "gh%s\n" p_abcdefghijklmnopqrstuvwxyz > "résumé notes.txt"'
catches 'tailnet detail' 'printf "machine.tail1234.ts.%s\n" net > a.txt'
catches 'path in a home folder' 'printf "see /Users/%s/x\n" someone > a.txt'
catches 'private network address' 'printf "ping 100.%s\n" 64.0.1 > a.txt'
catches 'private network address' 'printf "ping 192.%s\n" 168.0.1 > a.txt'
catches 'mention of a private file' 'printf "see PRODUCT-%s\n" PLAN > a.txt'
catches 'private word' 'id -un > a.txt'
catches 'private word' 'mkdir private && printf "zebra\n" > private/words && printf "a Zebra here\n" > a.txt'
catches 'private word' 'mkdir private && printf "zebra\n" > private/words && printf "zebra\n" >> .gitignore'
catches 'private word' 'mkdir private && printf zebra > private/words && printf "zebra\n" > a.txt'
catches 'private word in a file name' 'mkdir private && printf "zebra\n" > private/words && printf x > zebra-notes.txt'
if [ -n "$(git config --global user.email)" ]; then
	catches 'private word' 'git config --global user.email > a.txt'
fi
catches 'differs from what is staged' 'git init -q && git add -A && printf "changed\n" >> README.md'
catches 'no-reply address' 'git init -q && git add -A && git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -qm x'
catches 'access token' "git init -q && printf 'gh%s\n' p_abcdefghijklmnopqrstuvwxyz > a.txt && git add -A && $commit && git rm -q a.txt && $commit"

catches 'private files are in git history' "git init -q && mkdir .signing && printf x > .signing/password && git add -A && $commit && git rm -rq .signing && $commit"

planted=$(folder)
printf 'a sk-%s here\n' 'ant-abcdefghijklmnop' > "$planted/a.txt"
output=$("$check" "$planted" 2>&1)
if grep -qF 'a.txt:1' <<< "$output" && ! grep -qF 'abcdefghijklmnop' <<< "$output"; then
	echo "passed: the report names the file and line, not the secret"
else
	echo "MISSED: the report must name the file and line, not the secret"
	failures=$((failures + 1))
fi
rm -rf "$planted"

if [ "$failures" -ne 0 ]; then
	echo "$failures cases failed"
	exit 1
fi
echo "every case behaved"
