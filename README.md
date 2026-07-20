# GPU/NPU CUDA Image Processing

A Windows-focused C++17/CUDA project that processes a bundled RAW10 camera frame on the GPU. The `main` executable extracts IR and colour channels, interpolates and combines them into an RGB image, applies per-channel gains, and writes PNG outputs.

## Features

- CUDA RAW10 processing for the bundled 2592 × 1944 frame
- GPU kernels for green, red/blue, and IR extraction; convolution; bilinear interpolation; RGB composition; and gain adjustment
- PNG output through Windows Imaging Component (WIC)
- `CameraControl` wrapper around OpenCV video capture

## RAW10 pixel format

The input is a 2592 × 1944 RAW10 frame stored at `image/frame_6506.raw`. Each group of four pixels occupies five bytes; the application reads the packed rows with a 16-byte-aligned stride. The current frame layout uses a colour-plus-IR mosaic: green samples are extracted at full resolution, while red, blue, and IR samples are extracted at half resolution before RGB reconstruction.

Pixel layout (G = green, R = red, B = blue, Ir = infrared):
```
R   G    B    G   R    G    B    G
G   Ir   G    Ir  G    Ir   G    Ir
B   G    R    G   B    G    R    G
G   Ir   G    Ir  G    Ir   G    Ir
R   G    B    G   R    G    B    G
```
MIPI CSI-2 RAW10 packing:
```
Byte 0:  G0[9:2] | Byte 1: G1[9:2] | Byte 2: G2[9:2] | Byte 3: G3[9:2] | Byte 4: G0[1:0] G1[1:0] G2[1:0] G3[1:0]
```

## Processing flow

```mermaid
flowchart TD
    Input["RAW10 input<br/>image/frame_6506.raw"] --> Upload["Copy frame to GPU"]
    Upload --> Green["Extract green channel"]
    Upload --> RedBlueIR["Extract red, blue, and IR channels"]
    Green --> GreenFilter["Convolve green channel"]
    RedBlueIR --> RedFilter["Convolve red channel"]
    RedBlueIR --> BlueFilter["Convolve blue channel"]
    RedBlueIR --> IR["IR image"]
    RedFilter --> Interpolate["Bilinear interpolation"]
    BlueFilter --> Interpolate
    GreenFilter --> Compose["Compose RGB image"]
    Interpolate --> Compose
    Compose --> Gain["Apply RGB gains"]
    Gain --> RGB["rgb_image.png<br/>2592 × 1944"]
    IR --> IROutput["ir_image.png<br/>1296 × 972"]
```

## Requirements

- Windows
- CMake 3.18 or later
- A C++17-capable Visual Studio/MSVC installation
- CUDA Toolkit and a CUDA-capable NVIDIA GPU
- [vcpkg](https://github.com/microsoft/vcpkg) with the `opencv` dependency installed

The project uses the vcpkg toolchain automatically when the `VCPKG_ROOT` environment variable is set. `vcpkg.json` pins OpenCV to version 4.12.0 or later.

By default, CUDA targets are compiled for Blackwell (`sm_120`). For another supported GPU architecture, disable that option and specify your architecture during configuration.

## Build

In a Developer PowerShell for Visual Studio, configure and build the Debug executable:

```powershell
$env:VCPKG_ROOT = "C:\path\to\vcpkg"
cmake -S . -B build
cmake --build build --config Debug
```

For a non-Blackwell GPU, use a CUDA architecture appropriate for your hardware:

```powershell
cmake -S . -B build -DENABLE_BLACKWELL_ARCH=OFF -DCMAKE_CUDA_ARCHITECTURES=<architecture>
cmake --build build --config Debug
```

For example, replace `<architecture>` with `86` for an Ampere RTX 30-series GPU. If CMake cannot locate MSVC, run `vcvars64.bat` from the Visual Studio Build Tools installation before configuring.

## Run

Run the program from the repository root so it can locate `image/frame_6506.raw`:

```powershell
.\build\source\Debug\main.exe
```

Optional arguments set red, green, and blue gains:

```powershell
.\build\source\Debug\main.exe <redGain> <greenGain> <blueGain>
```

For example:

```powershell
.\build\source\Debug\main.exe 1.1 1.0 0.9
```

The program prints GPU information and per-kernel timings, then creates:

- `image/ir_image.png` — 1296 × 972 grayscale IR image
- `image/rgb_image.png` — 2592 × 1944 RGB image

It also asks Windows to open both files with their default associated application.

## Project layout

```text
source/
  main.cpp                    Executable entry point and PNG output
  image_processing/           CUDA RAW10-to-IR/RGB pipeline
  camera_control/             OpenCV camera wrapper (Later expansion to live webcam input)
image/frame_6506.raw          Sample RAW10 input frame
```
