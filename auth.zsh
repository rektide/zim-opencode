# @file auth.zsh
# @brief Rotate one provider's account in opencode's auth.json across multiple identities.
# @description
#   opencode's `auth.json` holds credentials for several providers (openai,
#   openrouter, zai, cerebras, opencode, ...). Only the rotating provider's
#   entry differs across accounts, so we store *just that entry* per account
#   and swap it in place — every other provider stays put in the live file.
#
#   Layout under `$OPENCODE_DIR` (default `~/.local/share/opencode`):
#   ```
#   auth.json                       # live file opencode reads (all providers)
#   auth.<provider>.<account>.json  # stored entry for one account
#   ```
#
#   A switch is a `jq` merge (`.[$provider] = <stored>`), never a whole-file
#   replace, so the live `auth.json` is always a real file — never a symlink
#   (opencode rewrites the file atomically and would orphan a symlink).
#
#   The stable id field (default `accountId` for `openai`) does not change
#   when access/refresh tokens rotate, so current-account detection is a
#   direct match of the live id against the store. No marker file needed.
#
#   Safety: `auth.json` → `auth.json.bak` before any changed overwrite, and
#   a warning is printed if `opencode` is currently running (it may rewrite
#   `auth.json` on exit).
#
#   Configuration via environment (all optional):
#   * `OPENCODE_PROVIDER` — which provider entry to rotate (default: `openai`).
#   * `OPENCODE_ID_FIELD` — stable id field within that provider (default: `accountId`).
#   * `OPENCODE_DIR`      — store / live-file location (default: `~/.local/share/opencode`).
#   * `OPENCODE_AUTH`     — the live auth file (default: `$OPENCODE_DIR/auth.json`).

# @description Resolve the store/live directory.
# Reads `$OPENCODE_DIR`, falling back to `~/.local/share/opencode`.
# @stdout The opencode data directory.
# @internal
_oc_dir() { print -r -- "${OPENCODE_DIR:-$HOME/.local/share/opencode}" }

# @description Resolve the live auth.json path.
# Reads `$OPENCODE_AUTH`, falling back to `$OPENCODE_DIR/auth.json`.
# @stdout Absolute path to the live auth file.
# @see _oc_dir
# @internal
_oc_auth() { print -r -- "${OPENCODE_AUTH:-$(_oc_dir)/auth.json}" }

# @description Resolve the provider whose entry is rotated.
# Reads `$OPENCODE_PROVIDER`, falling back to `openai`.
# @stdout Provider key as it appears in auth.json (e.g. `openai`).
# @internal
_oc_provider() { print -r -- "${OPENCODE_PROVIDER:-openai}" }

# @description Resolve the stable id field within the provider entry.
# Reads `$OPENCODE_ID_FIELD`, falling back to `accountId` (OpenAI's UUID).
# @stdout Field name used to identify an account across token rotations.
# @internal
_oc_idfield() { print -r -- "${OPENCODE_ID_FIELD:-accountId}" }

# @description Read the live id from auth.json for the configured provider.
# Used for current-account detection by matching against stored entries.
# @stdout The id (e.g. accountId UUID); empty if missing or auth.json unreadable.
# @see _oc_current
# @internal
_oc_live_id() {
	jq -r --arg p "$(_oc_provider)" --arg k "$(_oc_idfield)" \
		'.[$p][$k] // empty' "$(_oc_auth)" 2>/dev/null
}

# @description Identify the stored account whose id matches the live auth.
#
# Iterates the store and compares each stored id against the live one.
# Returns the first match (account names are unique per id by convention).
#
# @stdout The matching account name; empty if live id is empty or unmatched.
# @see _oc_live_id
# @internal
_oc_current() {
	local lid f sid name
	lid=$(_oc_live_id)
	[[ -n "$lid" ]] || return 0
	# (N) = NULLGLOB for this glob: pattern expands to nothing if no files match,
	# so the loop body never runs against a literal unmatched pattern.
	for f in "$(_oc_dir)"/auth.$(_oc_provider).*.json(N); do
		sid=$(jq -r --arg k "$(_oc_idfield)" '.[$k] // empty' "$f" 2>/dev/null)
		[[ "$sid" == "$lid" ]] || continue
		# ${f:t} = tail (basename); strip "auth.<provider>." prefix and ".json" suffix.
		name="${${f:t}#auth.$(_oc_provider).}"
		name="${name%.json}"
		print -r -- "$name"
		return
	done
}

# @description List stored account names for the configured provider, sorted.
# @stdout One account name per line, numerically-alphabetically ordered; empty if store missing.
# @internal
_oc_accounts() {
	local f name
	local -a out=()
	[[ -d "$(_oc_dir)" ]] || return 0
	for f in "$(_oc_dir)"/auth.$(_oc_provider).*.json(N); do
		name="${${f:t}#auth.$(_oc_provider).}"
		name="${name%.json}"
		out+=("$name")
	done
	# (@on) = order the array numerically, so acct2 sorts before acct10.
	print -rl -- "${(@on)out}"
}

# @description Snapshot the live provider entry to a named account's store file.
#
# Extracts just the rotating provider's object out of `auth.json` and writes
# it (atomically via temp+mv) to `auth.<provider>.<account>.json`. Sets
# `_oc_save_changed=1` if the snapshot differs from the existing file — used
# by `oc` to mark the rotation log when a refresh was captured.
#
# @arg $1 string Account name (the store filename stem).
# @set _oc_save_changed 1 if the snapshot newly captured a different entry, 0 otherwise.
# @exitcode 0 on success.
# @exitcode 1 if account is empty or auth.json is unreadable by jq.
# @see _oc_auth
# @internal
_oc_save_current() {
	local account="$1" dest tmp
	[[ -n "$account" ]] || return 1
	command mkdir -p "$(_oc_dir)"
	dest="$(_oc_dir)/auth.$(_oc_provider).$account.json"
	tmp="$dest.tmp.$$"   # PID-suffixed temp so concurrent oc calls don't collide
	typeset -g _oc_save_changed=0
	jq --arg p "$(_oc_provider)" '.[$p]' "$(_oc_auth)" > "$tmp" 2>/dev/null \
		|| { command rm -f "$tmp"; return 1; }
	[[ -f "$dest" ]] && ! command cmp -s "$dest" "$tmp" && _oc_save_changed=1
	command mv "$tmp" "$dest"
	command chmod 600 "$dest"
}

# @description Resolve a user-supplied name against the account list.
#
# Matching rules, in order:
#   1. exact match against the full needle, or against the local-part
#      (needle with `@<suffix>` stripped — supports `name@provider`);
#   2. otherwise, if the needle is a unique prefix of exactly one account,
#      return that account.
# Fails silently (no output) if there is no match or the prefix is ambiguous.
#
# @arg $1 string The handle, `handle@provider`, or unique prefix to resolve.
# @arg $@ string Candidate account names (argv after $1).
# @stdout The resolved account name, or empty if no/ambiguous match.
# @internal
_oc_resolve() {
	local needle="$1" a lp
	local -a m=()
	shift
	lp="${needle%@*}"   # local-part: strip @<realm> if present
	for a in "$@"; do
		if [[ "$a" == "$needle" || "$a" == "$lp" ]]; then
			print -r -- "$a"
			return
		fi
		[[ "$a" == "$lp"* ]] && m+=("$a")
	done
	# Resolve only on a unique prefix; ambiguous prefix intentionally returns nothing.
	(( ${#m[@]} == 1 )) && print -r -- "${m[1]}"
}

# @description Pick the next account after `$cur` in the list, with wraparound.
#
# Used by `oc` for the no-argument rotation: alphabetical order, wraps from
# the last entry back to the first. If `$cur` is not in the list (e.g. live
# identity is unknown), the first account is returned.
#
# @arg $1 string The current account name (may be empty).
# @arg $@ string The ordered account list.
# @stdout The next account name; empty if the list is empty.
# @internal
_oc_next() {
	local cur="$1" i n k
	shift
	local -a a=("$@")
	n=${#a[@]}
	[[ "$n" -eq 0 ]] && return 0
	for ((i = 1; i <= n; i++)); do
		[[ "${a[i]}" == "$cur" ]] && { k=$((i + 1)); break; }
	done
	[[ -z "$k" ]] && k=1
	((k > n)) && k=1
	print -r -- "${a[k]}"
}

# @description Restore a stored account into the live auth.json.
#
# Performs the `jq` merge: `.[$provider] = $entry`, where `$entry` is read
# from the stored account file via `--slurpfile`. Writes through a temp file
# and only replaces the live file if it actually changed; on change, the
# previous file is preserved as `auth.json.bak`.
#
# @arg $1 string Account name to restore.
# @stderr `oc: no account '<name>'` if the store file is missing.
# @exitcode 0 on success or no-op (unchanged).
# @exitcode 1 if the account file is missing or jq merge fails.
# @see _oc_save_current
# @internal
_oc_restore() {
	local account="$1" entry auth tmp
	entry="$(_oc_dir)/auth.$(_oc_provider).$account.json"
	auth="$(_oc_auth)"
	[[ -f "$entry" ]] || { print -u2 "oc: no account '$account'"; return 1; }
	tmp="$auth.tmp.$$"
	# --slurpfile e <file>: exposes the file's parsed content as $e[0].
	jq --slurpfile e "$entry" --arg p "$(_oc_provider)" \
		'.[$p] = $e[0]' "$auth" > "$tmp" 2>/dev/null \
		|| { command rm -f "$tmp"; return 1; }
	if command cmp -s "$tmp" "$auth"; then
		command rm -f "$tmp"   # no-op: stored entry already matches live
	else
		[[ -f "$auth" ]] && command cp "$auth" "$auth.bak"
		command mv "$tmp" "$auth"
		command chmod 600 "$auth"
	fi
}

# @description Warn if `opencode` is currently running.
#
# opencode may rewrite `auth.json` on exit, racing with our rotation. The
# warning is informational only — we proceed regardless.
#
# @stderr `oc: warning: opencode is running; auth.json may be rewritten on exit`
# @internal
_oc_running_warn() {
	pgrep -x opencode &>/dev/null \
		&& print -u2 "oc: warning: opencode is running; auth.json may be rewritten on exit"
}

# @description Rotate to the next account (no arg) or a specific account.
#
# Flow: identify the current account from the live id, snapshot its entry
# back to its store file, pick the next account (alphabetical, wraparound)
# or the explicitly requested one, then `jq`-merge the target entry into
# `auth.json`. Emits a single JSON line describing the rotation; a trailing
# ` *` marks that the outgoing save captured a refreshed token. Each rotation
# is also appended to `$XDG_STATE_HOME/oc.log` (or `~/.local/state/oc.log`).
#
# @example
#    oc                 # rotate to the next account alphabetically
#    oc work            # switch to the account named "work" (or unique prefix)
#    oc me@openai       # explicit provider-realm handle
#
# @arg $1 string Optional account name, prefix, or `name@provider` handle.
# @stdout JSON line: `{"identity":<to>,"provider":<p>,"from":<from>}`, with a trailing ` *` if the outgoing save captured a change.
# @stderr Diagnostics when current identity is unknown, no accounts exist, or the requested name doesn't match.
# @exitcode 0 on success.
# @exitcode 1 if accounts are missing, current identity can't be identified and no target was requested, or the requested name doesn't resolve.
# @see _oc_current _oc_save_current _oc_resolve _oc_next _oc_restore
oc() {
	emulate -L zsh
	local req="$1" cur next star=""
	typeset -g _oc_save_changed=0
	cur=$(_oc_current)
	_oc_running_warn
	if [[ -z "$cur" ]]; then
		if [[ -z "$req" ]]; then
			print -u2 "oc: can't identify current $(_oc_provider) identity; specify one explicitly"
			return 1
		fi
		print -u2 "oc: warning: current identity unknown; live auth not saved"
	else
		_oc_save_current "$cur"
	fi
	# (@f) = split command substitution's output on newlines into the array.
	local -a accounts=("${(@f)$(_oc_accounts)}")
	if (( ${#accounts[@]} == 0 )); then
		print -u2 "oc: no $(_oc_provider) identities in $(_oc_dir) — run ocImport first"
		return 1
	fi
	if [[ -n "$req" ]]; then
		next=$(_oc_resolve "$req" "${accounts[@]}")
		[[ -z "$next" ]] && { print -u2 "oc: no match for '$req' (have: ${accounts[*]})"; return 1; }
	else
		next=$(_oc_next "$cur" "${accounts[@]}")
	fi
	_oc_restore "$next"
	(( ${_oc_save_changed:-0} )) && star=" *"
	print "$(date -Iseconds) oc ${cur:-?} -> $next${req:+ ($req)}${star}" \
		>> "${XDG_STATE_HOME:-$HOME/.local/state}/oc.log"
	print "{\"identity\":\"$next\",\"provider\":\"$(_oc_provider)\",\"from\":\"${cur:-unknown}\"}$star"
}

# @description List stored accounts for the configured provider.
#
# One row per account: `*` marks the current account (matched by live id),
# followed by the account name, the first 8 chars of its stable id, and the
# access-token expiry parsed from the stored `expires` epoch-ms field.
#
# @stdout Formatted rows: `<*| > <name> <id[:8]> exp=<YYYY-MM-DD HH:MM>`.
# @see _oc_current _oc_accounts
ocLs() {
	emulate -L zsh
	local cur=$(_oc_current) a f id exp expstr mark
	for a in "${(@f)$(_oc_accounts)}"; do
		f="$(_oc_dir)/auth.$(_oc_provider).$a.json"
		id=$(jq -r --arg k "$(_oc_idfield)" '.[$k] // "??"' "$f" 2>/dev/null)
		exp=$(jq -r '.expires // 0' "$f" 2>/dev/null)
		expstr="?"
		# expires is epoch-ms; gate on a numeric value before calling date.
		[[ "$exp" == <-> && "$exp" -gt 0 ]] \
			&& expstr=$(date -d "@$((exp / 1000))" +"%F %H:%M" 2>/dev/null)
		mark=" "; [[ "$a" == "$cur" ]] && mark="*"
		printf '%s %-12s %-14s exp=%s\n' "$mark" "$a" "${id:0:8}" "$expstr"
	done
}

# @description Print a provider's entry as JSON, from the live file or a stored account.
#
# With no account argument, prints the live `auth.json[$provider]` entry.
# With an account argument, prints the stored entry for `<provider>/<account>`
# from its snapshot file.
#
# @example
#    ocProvider openai                  # current live openai entry
#    ocProvider openrouter main         # stored openrouter/main entry
#
# @arg $1 string Provider key (defaults to the rotating provider).
# @arg $2 string Optional account name to read from the store instead of the live file.
# @stdout The provider entry as pretty-printed JSON.
# @stderr `ocProvider: no <provider>/<account>` if the store file is missing.
# @exitcode 0 on success.
# @exitcode 1 if a requested account file is missing.
ocProvider() {
	emulate -L zsh
	local provider="${1:-$(_oc_provider)}" account="$2" f
	if [[ -n "$account" ]]; then
		f="$(_oc_dir)/auth.$provider.$account.json"
		[[ -f "$f" ]] || { print -u2 "ocProvider: no $provider/$account"; return 1; }
		jq '.' "$f"
	else
		jq --arg p "$provider" '.[$p] // empty' "$(_oc_auth)"
	fi
}

# @description Seed the store from legacy `auth.json.<name>` snapshots.
#
# Scans `$OPENCODE_DIR` for `auth.json.*` files left over from a previous
# whole-file rotation scheme (one such file per saved identity). For each
# file that contains the rotating provider's entry, extracts just that entry
# into the new `auth.<provider>.<name>.json` layout. Skips `.bak` and
# `.tmp*` files. If the live `auth.json` is a symlink, replaces it with a
# real copy (opencode rewrites the file atomically and would orphan a
# symlink). Finally re-snapshots the current identity's entry into its own
# store file.
#
# Safe to re-run: existing per-account files are simply overwritten.
#
# @stdout Summary: `imported N identit(y|ies) into <dir> (current: <name|none>)`.
# @see _oc_current _oc_save_current
ocImport() {
	emulate -L zsh
	local f name count=0 cur target
	command mkdir -p "$(_oc_dir)"
	for f in "$(_oc_dir)"/auth.json.*(N); do
		name="${${f:t}#auth.json.}"
		[[ "$name" == "bak" || "$name" == tmp* ]] && continue
		# jq -e: exit non-zero (skip via `|| continue`) if the provider entry is absent/null.
		jq -e --arg p "$(_oc_provider)" '.[$p]' "$f" >/dev/null 2>&1 || continue
		jq --arg p "$(_oc_provider)" '.[$p]' "$f" \
			> "$(_oc_dir)/auth.$(_oc_provider).$name.json"
		command chmod 600 "$(_oc_dir)/auth.$(_oc_provider).$name.json"
		count=$((count + 1))
	done
	if [[ -L "$(_oc_auth)" ]]; then
		target=$(readlink -f "$(_oc_auth)")
		command rm "$(_oc_auth)"
		command cp "$target" "$(_oc_auth)"
		command chmod 600 "$(_oc_auth)"
	fi
	cur=$(_oc_current)
	[[ -n "$cur" ]] && _oc_save_current "$cur"
	print "imported $count $(_oc_provider) identit$([[ $count -eq 1 ]] && echo y || echo ies) into $(_oc_dir) (current: ${cur:-none})"
}
