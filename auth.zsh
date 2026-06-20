_oc_dir() { print -r -- "${OPENCODE_DIR:-$HOME/.local/share/opencode}" }
_oc_auth() { print -r -- "${OPENCODE_AUTH:-$(_oc_dir)/auth.json}" }
_oc_provider() { print -r -- "${OPENCODE_PROVIDER:-openai}" }
_oc_idfield() { print -r -- "${OPENCODE_ID_FIELD:-accountId}" }

_oc_live_id() {
	jq -r --arg p "$(_oc_provider)" --arg k "$(_oc_idfield)" '.[$p][$k] // empty' "$(_oc_auth)" 2>/dev/null
}

_oc_current() {
	local lid f sid name
	lid=$(_oc_live_id)
	[[ -n "$lid" ]] || return 0
	for f in "$(_oc_dir)"/auth.$(_oc_provider).*.json(N); do
		sid=$(jq -r --arg k "$(_oc_idfield)" '.[$k] // empty' "$f" 2>/dev/null)
		[[ "$sid" == "$lid" ]] || continue
		name="${${f:t}#auth.$(_oc_provider).}"
		name="${name%.json}"
		print -r -- "$name"
		return
	done
}

_oc_accounts() {
	local f name
	local -a out=()
	[[ -d "$(_oc_dir)" ]] || return 0
	for f in "$(_oc_dir)"/auth.$(_oc_provider).*.json(N); do
		name="${${f:t}#auth.$(_oc_provider).}"
		name="${name%.json}"
		out+=("$name")
	done
	print -rl -- "${(@on)out}"
}

_oc_save_current() {
	local account="$1" dest tmp
	[[ -n "$account" ]] || return 1
	command mkdir -p "$(_oc_dir)"
	dest="$(_oc_dir)/auth.$(_oc_provider).$account.json"
	tmp="$dest.tmp.$$"
	typeset -g _oc_save_changed=0
	jq --arg p "$(_oc_provider)" '.[$p]' "$(_oc_auth)" > "$tmp" 2>/dev/null || { command rm -f "$tmp"; return 1; }
	[[ -f "$dest" ]] && ! command cmp -s "$dest" "$tmp" && _oc_save_changed=1
	command mv "$tmp" "$dest"
	command chmod 600 "$dest"
}

_oc_resolve() {
	local needle="$1" a lp
	local -a m=()
	shift
	lp="${needle%@*}"
	for a in "$@"; do
		if [[ "$a" == "$needle" || "$a" == "$lp" ]]; then
			print -r -- "$a"
			return
		fi
		[[ "$a" == "$lp"* ]] && m+=("$a")
	done
	(( ${#m[@]} == 1 )) && print -r -- "${m[1]}"
}

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

_oc_restore() {
	local account="$1" entry auth tmp
	entry="$(_oc_dir)/auth.$(_oc_provider).$account.json"
	auth="$(_oc_auth)"
	[[ -f "$entry" ]] || { print -u2 "oc: no account '$account'"; return 1; }
	tmp="$auth.tmp.$$"
	jq --slurpfile e "$entry" --arg p "$(_oc_provider)" '.[$p] = $e[0]' "$auth" > "$tmp" 2>/dev/null || { command rm -f "$tmp"; return 1; }
	if command cmp -s "$tmp" "$auth"; then
		command rm -f "$tmp"
	else
		[[ -f "$auth" ]] && command cp "$auth" "$auth.bak"
		command mv "$tmp" "$auth"
		command chmod 600 "$auth"
	fi
}

_oc_running_warn() {
	pgrep -x opencode &>/dev/null && print -u2 "oc: warning: opencode is running; auth.json may be rewritten on exit"
}

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
	print "$(date -Iseconds) oc ${cur:-?} -> $next${req:+ ($req)}${star}" >> "${XDG_STATE_HOME:-$HOME/.local/state}/oc.log"
	print "{\"identity\":\"$next\",\"provider\":\"$(_oc_provider)\",\"from\":\"${cur:-unknown}\"}$star"
}

ocLs() {
	emulate -L zsh
	local cur=$(_oc_current) a f id exp expstr mark
	for a in "${(@f)$(_oc_accounts)}"; do
		f="$(_oc_dir)/auth.$(_oc_provider).$a.json"
		id=$(jq -r --arg k "$(_oc_idfield)" '.[$k] // "??"' "$f" 2>/dev/null)
		exp=$(jq -r '.expires // 0' "$f" 2>/dev/null)
		expstr="?"
		[[ "$exp" == <-> && "$exp" -gt 0 ]] && expstr=$(date -d "@$((exp / 1000))" +"%F %H:%M" 2>/dev/null)
		mark=" "; [[ "$a" == "$cur" ]] && mark="*"
		printf '%s %-12s %-14s exp=%s\n' "$mark" "$a" "${id:0:8}" "$expstr"
	done
}

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

ocImport() {
	emulate -L zsh
	local f name count=0 cur target
	command mkdir -p "$(_oc_dir)"
	for f in "$(_oc_dir)"/auth.json.*(N); do
		name="${${f:t}#auth.json.}"
		[[ "$name" == "bak" || "$name" == tmp* ]] && continue
		jq -e --arg p "$(_oc_provider)" '.[$p]' "$f" >/dev/null 2>&1 || continue
		jq --arg p "$(_oc_provider)" '.[$p]' "$f" > "$(_oc_dir)/auth.$(_oc_provider).$name.json"
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
