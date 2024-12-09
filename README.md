<h3 align="center">
    Zig WebGPU Graphics
</h3>

This repo is my exploration into how graphics work

It uses wgpu-native and is based on this [cpp series](https://eliemichel.github.io/LearnWebGPU/index.html)

Nix is the build tool

I fetch wgpu-native and glfw3 through the nix flake

The [flake.nix](./flake.nix) uses [zig2nix](https://github.com/Cloudef/zig2nix) for building 
and running the code via Vulkan

## Running

To run the code, simply run:
```
nix run github:ethanthoma/graphics
```
Or clone the repo locally and run `nix run`.

> [!NOTE]
> This is only tested on Wayland w/ Vulkan, no promises outside of that
