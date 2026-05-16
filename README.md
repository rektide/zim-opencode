# zim-opencode

> [Zimfw](https://zimfw.sh/) module to initialize [opencode](https://opencode.ai) shell completions.

## What it does

Automatically generates and caches zsh completions for `opencode`. The completion file is regenerated whenever the `opencode` binary is newer than the cached completions, so upgrades are handled without manual intervention.

## Install

In `~/.zimrc`:

```zsh
zmodule rektide/zim-opencode
```

Then:

```zsh
zimfw install
```

## How it works

The module loads in [`init.zsh`](init.zsh) and does two things:

1. Exits early if `opencode` is not found in `$PATH`
2. Writes completions to `functions/_opencode` if the file is missing or stale (older than the `opencode` binary)

`opencode completion` outputs yargs-based zsh completions directly, so no shell name argument is needed.
