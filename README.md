# Kero

A native terminal workspace for macOS.

![preview](https://kero.sh/kero-screenshot.png)

## Features

- Swift + libghostty by default, with an optional Alacritty backend
- Native design
- Split panes
- Git intergration
- Group by projects
- File tree

## Terminal backends

Kero uses libghostty by default. You can choose Alacritty for new terminal
sessions in **Settings → Terminal → Backend**; existing sessions keep the
backend they were created with.

The Alacritty option embeds the `alacritty_terminal` emulator core and draws it
with Kero's own Metal renderer. It supports Kero's normal terminal workflow,
including themes, selection, scrollback, find, clipboard protection, links,
mouse-aware TUIs, restored history, remote working-directory reports, OSC 9
notifications, and OSC 9;4 progress.

Compared with libghostty, the Alacritty backend currently does not support:

- terminal graphics protocols
- the Kitty keyboard protocol

## Download

https://kero.sh

Or with Homebrew:

```sh
brew install egoist/tap/kero
```

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## License

GPLv3
