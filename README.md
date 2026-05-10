# ZIM - Zig installation manager

Zim is a cli tool to download and manages multiple versions of zig and zls.

> Zim is currently incompatible with Windows

```
info: Usage: zim <command> [args]

Commands:
  install, i     Download a Zig version
  use, u         Select an installed version
  list, ls       List installed zig versions
  remove, rm     Delete a installed version
  help, h        Show this message

General options:
  -h, --help     Show command-specific usage
```

```
Usage: zim install <version> [options]

Fetch a version of Zig (and optionally ZLS) and select it
as the active version. <version> is a semver like `0.14.1`
or `master`.

Options:
  --zls          Also install ZLS
  --force        Re-install if already present
  -h, --help     Show this help
```

```
> zim f 0.16.0 --zls
[3] zim
├─ installing zig-x86_64-linux-0.16.0.tar.xz from https://zig-mirror.tsimnet.eu/zig
└─ [84/100] extract
```

# Installation

Downlaod the Zim executable from the release page or compile from source. Place
the `zim` executable somewhere on your `PATH`.

Add the symlink directory to your `PATH`:

```sh
export PATH="/path/to/zim-data/bin:$PATH"
```

The `zim-data` directory is created next to the `zim` executable and holds all
fetched versions and the active symlinks.

## Autocomplete

Zim ships with a built-in completion provider. Add the appropriate line to your
shell's startup file.

### Bash

```sh
complete -C 'zim autocomplete' zim
```

Add it to `~/.bashrc` (Linux) or `~/.bash_profile` (macOS).

### Zsh

```sh
autoload -U +X bashcompinit && bashcompinit
complete -C 'zim autocomplete' zim
```

Add it to `~/.zshrc`. This is the right setup for the default shell on macOS.
