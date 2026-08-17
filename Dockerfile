FROM nvidia/cuda:13.3.0-devel-ubuntu24.04

ARG CUDA_ARCHITECTURES=120

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        cmake \
        libopencv-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY CMakeLists.txt ./
COPY source ./source
COPY image ./image

RUN test -f image/frame_6506.raw \
    && cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
        -DBUILD_CAMERA_CONTROL=OFF \
    && cmake --build build --parallel \
    && cmake --install build

ENTRYPOINT ["/usr/local/bin/main"]
