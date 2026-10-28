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

| Action           | Key                |
| ---------------- | ------------------ |
| New tab          | `Ctrl+Shift+T`     |
| Close pane       | `Ctrl+Shift+W`     |
| Next tab         | `Ctrl+Shift+N`     |
| Previous tab     | `Ctrl+Shift+P`     |
| Vertical split   | `Ctrl+Shift+Enter` |
| Horizontal split | `Alt+Shift+Enter`  |
| Navigate panes   | `Ctrl+Shift+Arrow` |
| Resize panes     | `Alt+Shift+Arrow`  |

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

