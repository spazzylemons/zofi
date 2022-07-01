# zofi

A straightforward Wayland application launcher similar to rofi and bemenu.

## Building

- GTK 3
- gtk-layer-shell
- pkg-config
- The latest version of Zig

Run `zig build` to build zofi. The executable is placed at `zig-out/bin/zofi`.
See [this link](https://ziglang.org/documentation/master/#Build-Mode) for
building an optimized binary.

## Usage

zofi runs in Wayland compositors that support the layer shell protocol. You can
use `wayland-info` within a compositor to check for support.

## License

zofi is licensed under the MIT License.
