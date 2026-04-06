# canvas-zpix

Image I/O bridge between [zpix](https://github.com/diogok/zpix) (PNG/JPEG codec) and [canvas](../canvas) (2D drawing).

## Features

- Load PNG/JPEG files into RGBA pixel data for `surface.drawImage()`
- `ImageRenderer` captures canvas output to PNG for headless rendering, screenshots, and CI
- Draw rectangular sub-regions of an image (sprite sheet support)

## Usage

### Install

```sh
zig fetch --save git+https://github.com/make-it-render/canvas-zpix
```

### build.zig

```zig
const canvas_zpix_dep = b.dependency("canvas_zpix", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("canvas_zpix", canvas_zpix_dep.module("canvas_zpix"));
```

### Example

```zig
const canvas_zpix = @import("canvas_zpix");
const Image = canvas_zpix.Image;
const ImageRenderer = canvas_zpix.ImageRenderer;

// Load and draw an image
var img = try Image.init(allocator, "assets/player.png");
defer img.deinit();
img.draw(&surface, 100, 50);

// Draw a sub-region (sprite from a sheet)
img.drawRegion(&surface, 0, 0, 16, 16, 100, 50);

// Or create from raw RGBA pixels
var raw = try Image.initFromRgba(allocator, &pixels, 4, 4);
defer raw.deinit();
```

## API

### Image

| Method | Description |
|--------|-------------|
| `init(allocator, path)` | Load PNG/JPEG from file (auto-detected) |
| `initFromMemory(allocator, data)` | Load from memory buffer |
| `initFromRgba(allocator, pixels, width, height)` | Create from raw RGBA data |
| `draw(surface, x, y)` | Draw onto a canvas Surface |
| `drawRegion(surface, src_x, src_y, src_w, src_h, dst_x, dst_y)` | Draw a sub-rectangle |
| `deinit()` | Free resources |

### ImageRenderer

A canvas `Renderer` that captures output to an in-memory pixel buffer. Enables headless rendering without a display server.

```zig
var renderer = try ImageRenderer.init(allocator, 800, 600);
defer renderer.deinit();
var canvas = Canvas.init(allocator, renderer.renderer());
// ... draw scene ...
try canvas.draw();
try renderer.savePng("screenshot.png");
```

| Method | Description |
|--------|-------------|
| `init(allocator, width, height)` | Create a renderer with given dimensions |
| `renderer()` | Get the type-erased `Renderer` interface |
| `getPixels()` | Access the raw RGBA pixel buffer |
| `getPixel(x, y)` | Get RGBA value at a coordinate |
| `savePng(path)` | Encode and save to a PNG file |
| `deinit()` | Free resources |

## Build and test

```sh
zig build test --summary all
```

## License

MIT License

Copyright (c) Diogo Souza da Silva
