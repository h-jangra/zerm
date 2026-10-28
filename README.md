# zerm

Minimal terminal multiplexer with tabs and splits.

It focuses on a simple, modern workflow with **tabs and splits** — without sessions, daemons, or complex configuration.

## Features

* Tabs
* Horizontal & vertical splits
* Pane navigation & resizing
* Mouse support
* Terminal scrollback
* VT100/ANSI terminal emulation
* TrueColor & 256 colors
* Alternate screen support
* Configurable keybindings
* Zero dependencies

## Keybindings

| Action           | Key                          |
| ---------------- | ---------------------------- |
| New tab          | `Ctrl+Shift+T` / `Alt+T`     |
| Close pane       | `Ctrl+Shift+W` / `Alt+W`     |
| Next tab         | `Ctrl+Tab` / `Alt+N`         |
| Previous tab     | `Ctrl+Shift+Tab` / `Alt+P`   |
| Vertical split   | `Ctrl+Shift+Enter` / `Alt+V` |
| Horizontal split | `Ctrl+Shift+D` / `Alt+D`     |
| Navigate panes   | `Alt+Arrow` / `Alt+HJKL`     |
| Resize panes     | `Alt+Shift+Arrow`            |

New tabs and splits open in the working directory of the focused pane. Keys
that have no legacy encoding (such as `Shift+Enter` and `Ctrl+Tab`) are
forwarded to applications using the keyboard protocol they requested, so
`Shift+Enter` inserts a newline in TUI apps.

Closing a pane or tab that is running a full-screen app (opencode, nvim, htop,
...) asks for confirmation first. Closing an idle shell does not.

## Build

```bash
zig build
```

## Run

```bash
./zig-out/bin/zerm
```

Requires **Zig 0.17+** and Linux/Unix.

## License

MIT

