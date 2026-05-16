# framing by-way-of zim-mise, passing in directory holding the script
(( ${+commands[opencode]} )) && () {
  local command=${commands[opencode]}

    # generating completions
  local compfile=$1/functions/_opencode
  if [[ ! -e $compfile || $compfile -ot $command ]]; then
    $command completion >| $compfile
    print -u2 -PR "* Detected a new version of 'opencode'. Regenerated completions."
  fi
} ${0:h}
