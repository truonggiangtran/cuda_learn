#include <cuda_runtime.h>
#include <chrono>
#include <cstdio>
#include <algorithm>
#include "image_processing.h"

// constexpr int TILE_SIZE = 16;
constexpr float kernelMat[9] = {
    0.00f, 0.25f, 0.00f,
    0.25f, 1.00f, 0.25f,
    0.00f, 0.25f, 0.00f
};

__constant__ float d_kernelMat[9];
template <typename T>
__device__ inline T clamp(T value, T minVal, T maxVal) {
    return max(minVal, min(value, maxVal));
}

template <typename T, typename... Args>
__host__ void cudaMethodRunner(const char* methodName, T kernelFunc, dim3 gridDim, dim3 blockDim, Args&&... args) {
    cudaError_t err = cudaSuccess;

    auto start = std::chrono::high_resolution_clock::now();
    kernelFunc<<<gridDim, blockDim>>>(std::forward<decltype(args)>(args)...);
    err = cudaGetLastError();
    if (err != cudaSuccess) {
        fprintf(stderr, "Failed to launch %s kernel (error code %s)!\n", methodName, cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
    
    err = cudaDeviceSynchronize();
    if (err != cudaSuccess) {
        fprintf(stderr, "%s kernel failed during execution (error code %s)!\n", methodName, cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
    auto end = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double, std::milli> elapsed = end - start;
    printf("%s kernel execution time: %.3f ms\n", methodName, elapsed.count());
}

__host__ void cudaMemoryDebug(const unsigned char *devicePtr, size_t size, const char* varName) {
    unsigned char* hostBuffer = new unsigned char[size];
    cudaError_t err = cudaMemcpy(hostBuffer, devicePtr, size, cudaMemcpyDeviceToHost);
    if (err != cudaSuccess) {
        fprintf(stderr, "Failed to copy %s from device to host (error code %s)!\n", varName, cudaGetErrorString(err));
        delete[] hostBuffer;
        exit(EXIT_FAILURE);
    }
    printf("data of %s:\n", varName);
    for (size_t i = 2592; i < 2642; ++i) {
        printf("%02X ", hostBuffer[i]);
    }
    printf("\n");
    delete[] hostBuffer;
}

__global__ void greenExtract_kernel(const unsigned char* raw10, unsigned char* gImage, int width, int height, int stride) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x < width && y < height) {
        if ((y % 2 == 0 && x % 2 == 1) || (y % 2 == 1 && x % 2 == 0)) { // Green pixel
            gImage[y * width + x] = raw10[y * stride + (x / 4) * 5 + (x % 4)];
        } else {
            gImage[y * width + x] = 0; // Not a green pixel
        }
    }
}
__global__ void redblueIRExtract_kernel(const unsigned char* raw10, unsigned char* rImage, unsigned char* bImage, unsigned char* irImage, int width, int height, int stride) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x >= width || y >= height) return;

    if (y % 2 == 0 && x % 2 == 0) { // Blue pixel
        bImage[y * width + x] = raw10[y * 2 * stride + (x / 2) * 5];
    } else if (y % 2 == 1 && x % 2 == 1) {
        bImage[y * width + x] = raw10[(y * 2 + 1) * stride + (x / 2) * 5 + 2];
    } else {
        bImage[y * width + x] = 0; // Not a blue pixel
    }

    if (y % 2 == 0 && x % 2 == 1) { // Red pixel
        rImage[y * width + x] = raw10[y * 2 * stride + (x / 2) * 5 + 2];
    } else if (y % 2 == 1 && x % 2 == 0) {
        rImage[y * width + x] = raw10[(y * 2 + 1) * stride + (x / 2) * 5];
    } else {
        rImage[y * width + x] = 0; // Not a red pixel
    }

    irImage[y * width + x] = raw10[(2 * y + 1) * stride + (x / 2) * 5 + (x % 2) * 2 + 1]; // IR pixel
    // if (x < 50 && y  < 5)
    //     printf("IR pixel at (%d, %d): %u raw10 at (%d, %d): %u\n", x, y, irImage[y * width + x], (x / 2) * 5 + (x % 2) * 2 + 1, (2 * y + 1), raw10[(2 * y + 1) * stride + (x / 2) * 5 + (x % 2) * 2 + 1]);

}
__global__ void convolution_kernel(const unsigned char* input, unsigned char* output, int width, int height) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    float sum = 0.0f;

    if (x >= width || y >= height) return;

    // sum =   kernelMat[0] * input[max(0, min(y - 1, height - 1)) * width + max(0, min(x - 1, width - 1))] + 
    //         kernelMat[1] * input[max(0, min(y - 1, height - 1)) * width + max(0, min(x, width - 1))] + 
    //         kernelMat[2] * input[max(0, min(y - 1, height - 1)) * width + max(0, min(x + 1, width - 1))] + 
    //         kernelMat[3] * input[max(0, min(y, height - 1)) * width + max(0, min(x - 1, width - 1))] + 
    //         kernelMat[4] * input[max(0, min(y, height - 1)) * width + max(0, min(x, width - 1))] + 
    //         kernelMat[5] * input[max(0, min(y, height - 1)) * width + max(0, min(x + 1, width - 1))] + 
    //         kernelMat[6] * input[max(0, min(y + 1, height - 1)) * width + max(0, min(x - 1, width - 1))] + 
    //         kernelMat[7] * input[max(0, min(y + 1, height - 1)) * width + max(0, min(x, width - 1))] + 
    //         kernelMat[8] * input[max(0, min(y + 1, height - 1)) * width + max(0, min(x + 1, width - 1))];
    for (int i = 0; i < 9; ++i) {
        sum += d_kernelMat[i] * input[clamp(y + (i / 3) - 1, 0, height - 1) * width + clamp(x + (i % 3) - 1, 0, width - 1)];
    }
    output[y * width + x] = static_cast<unsigned char>(sum);
}
__global__ void bilinear_interpolate_kernel(const unsigned char* red, const unsigned char* blue, unsigned char* dest_red, unsigned char* dest_blue, int width, int height, float scaleX, float scaleY) {
    // width and height are the dimensions of the destination image
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x >= width || y >= height) return;

    // Calculate the corresponding coordinates in the input image
    if (scaleX == 0 || scaleY == 0) return; // Avoid division by zero

    // Calculate the source image dimensions
    int srcWidth = max(1, static_cast<int>(width / scaleX));
    int srcHeight = max(1, static_cast<int>(height / scaleY));

    // Calculate the source coordinates
    float srcX = (x + 0.5f) / scaleX - 0.5f;
    float srcY = (y + 0.5f) / scaleY - 0.5f;
    // Clamp the source coordinates to be within the bounds of the source image
    srcX = clamp(srcX, 0.0f, static_cast<float>(srcWidth - 1));
    srcY = clamp(srcY, 0.0f, static_cast<float>(srcHeight - 1));

    // Calculate the integer coordinates of the surrounding pixels
    int x0 = static_cast<int>(floorf(srcX));
    int y0 = static_cast<int>(floorf(srcY));
    int x1 = min(x0 + 1, srcWidth - 1);
    int y1 = min(y0 + 1, srcHeight - 1);

    // Calculate the weights for interpolation
    float wx = srcX - x0;
    float wy = srcY - y0;

    // Perform bilinear interpolation
    float redVal = (1.0f - wx) * (1.0f - wy) * red[y0 * srcWidth + x0]
                 + wx * (1.0f - wy) * red[y0 * srcWidth + x1]
                 + (1.0f - wx) * wy * red[y1 * srcWidth + x0]
                 + wx * wy * red[y1 * srcWidth + x1];

    float blueVal = (1.0f - wx) * (1.0f - wy) * blue[y0 * srcWidth + x0]
                  + wx * (1.0f - wy) * blue[y0 * srcWidth + x1]
                  + (1.0f - wx) * wy * blue[y1 * srcWidth + x0]
                  + wx * wy * blue[y1 * srcWidth + x1];

    dest_red[y * width + x] = static_cast<unsigned char>(redVal + 0.5f);
    dest_blue[y * width + x] = static_cast<unsigned char>(blueVal + 0.5f);
}
__global__ void combine_rgb_kernel(const unsigned char* red, const unsigned char* green, const unsigned char* blue, unsigned char* rgbImage, int width, int height) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x >= width || y >= height) return;
    int idx = (y * width + x) * 3;
    rgbImage[idx + 2] = red[y * width + x];
    rgbImage[idx + 1] = green[y * width + x];
    rgbImage[idx] = blue[y * width + x];
}
__global__ void balance_rgb_kernel(unsigned char* rgbImage, int width, int height, float rGain, float gGain, float bGain) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x >= width || y >= height) return;

    int idx = (y * width + x) * 3;
    rgbImage[idx] = static_cast<unsigned char>(min(255.0f, rgbImage[idx] * rGain));
    rgbImage[idx + 1] = static_cast<unsigned char>(min(255.0f, rgbImage[idx + 1] * gGain));
    rgbImage[idx + 2] = static_cast<unsigned char>(min(255.0f, rgbImage[idx + 2] * bGain));
}
__global__ void flip_image_kernel(unsigned char* image, int width, int height, int channels) {
    // Flip image horizontally
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x >= width || y >= height) return;
    int idx = (y * width + x) * channels;
    int mirrorIdx = (width - y - 1) * width * channels + x * channels;
    for (int c = 0; c < channels; ++c) {
        unsigned char temp = image[idx + c];
        image[idx + c] = image[mirrorIdx + c];
        image[mirrorIdx + c] = temp;
    }
}
// __global__ void auto_white_balancing_kernel(unsigned char* rgbImage, int width, int height) {
//     int x = blockIdx.x * blockDim.x + threadIdx.x;
//     int y = blockIdx.y * blockDim.y + threadIdx.y;

//     if (x >= width || y >= height) return;
//     int idx = (y * width + x) * 3;


// }
void read_gpu() {
    int deviceCount = 0;
    cudaGetDeviceCount(&deviceCount);

    for (int deviceId = 0; deviceId < deviceCount; ++deviceId) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, deviceId);

        printf("=== GPU: %s ===\n", prop.name);

        printf("\n--- Architecture ---\n");
        printf("Compute Capability:      %d.%d\n", prop.major, prop.minor);
        printf("SM Count:                %d\n", prop.multiProcessorCount);
        printf("Warp Size:               %d\n", prop.warpSize);

        printf("\n--- Thread Limits ---\n");
        printf("Max Threads/Block:       %d\n", prop.maxThreadsPerBlock);
        printf("Max Threads/SM:          %d\n", prop.maxThreadsPerMultiProcessor);
        printf("Max Warps/SM:            %d\n", prop.maxThreadsPerMultiProcessor / prop.warpSize);
        printf("Max Block Dim:           (%d, %d, %d)\n",
               prop.maxThreadsDim[0], prop.maxThreadsDim[1], prop.maxThreadsDim[2]);
        printf("Max Grid Dim:            (%d, %d, %d)\n",
               prop.maxGridSize[0], prop.maxGridSize[1], prop.maxGridSize[2]);

        printf("\n--- Memory ---\n");
        printf("Global Memory:           %zu MB\n", prop.totalGlobalMem / (1024 * 1024));
        printf("Shared Memory/Block:     %zu KB\n", prop.sharedMemPerBlock / 1024);
        printf("Shared Memory/SM:        %zu KB\n", prop.sharedMemPerMultiprocessor / 1024);
        printf("Registers/Block:         %d\n", prop.regsPerBlock);
        printf("Registers/SM:            %d\n", prop.regsPerMultiprocessor);
        printf("L2 Cache:                %d KB\n", prop.l2CacheSize / 1024);
        printf("Memory Bus Width:        %d bits\n", prop.memoryBusWidth);

        printf("\n--- Computed Limits ---\n");
        printf("Max Concurrent Threads:  %d\n",
               prop.maxThreadsPerMultiProcessor * prop.multiProcessorCount);
        printf("Theoretical Bandwidth:   unavailable\n\n");
    }
}

void checkCudaError(cudaError_t err, const char* msg) {
    if (err != cudaSuccess) {
        fprintf(stderr, "%s (error code %s)!\n", msg, cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}

void image_processing(unsigned char* tempBuffer, int width, int height, int stride, unsigned char* irImage, unsigned char* rgbImage, float rGain, float gGain, float bGain) {
    cudaError_t err = cudaSuccess;

    constexpr int blockDimX = 16;
    constexpr int blockDimY = 16;
    int gridSizeX = (width + blockDimX - 1) / blockDimX;
    int gridSizeY = (height + blockDimY - 1) / blockDimY;
    int halfWidth = width / 2;
    int halfHeight = height / 2;
    int rbGridSizeX = (halfWidth + blockDimX - 1) / blockDimX;
    int rbGridSizeY = (halfHeight + blockDimY - 1) / blockDimY;

    // Allocate device memory
    unsigned char* d_tempBuffer = nullptr;
    unsigned char* d_irImage = nullptr;
    unsigned char* d_rImage = nullptr;
    unsigned char* d_gImage = nullptr;
    unsigned char* d_bImage = nullptr;
    unsigned char* d_resized_rImage = nullptr;
    unsigned char* d_resized_bImage = nullptr;
    unsigned char* d_rgbImage = nullptr;

    err = cudaMalloc((void**)&d_tempBuffer, height * stride);
    checkCudaError(err, "Failed to allocate device memory for tempBuffer");
    err = cudaMalloc((void**)&d_irImage, width * height / 4);
    checkCudaError(err, "Failed to allocate device memory for irImage");
    err = cudaMalloc((void**)&d_rImage, width * height / 4);
    checkCudaError(err, "Failed to allocate device memory for rImage");
    err = cudaMalloc((void**)&d_gImage, width * height);
    checkCudaError(err, "Failed to allocate device memory for gImage");
    err = cudaMalloc((void**)&d_bImage, width * height / 4);
    checkCudaError(err, "Failed to allocate device memory for bImage");
    err = cudaMalloc((void**)&d_resized_rImage, width * height);
    checkCudaError(err, "Failed to allocate device memory for resized_rImage");
    err = cudaMalloc((void**)&d_resized_bImage, width * height);
    checkCudaError(err, "Failed to allocate device memory for resized_bImage");
    err = cudaMalloc((void**)&d_rgbImage, width * height * 3);
    checkCudaError(err, "Failed to allocate device memory for rgbImage");

    err = cudaMemcpy(d_tempBuffer, tempBuffer, height * stride, cudaMemcpyHostToDevice);
    checkCudaError(err, "Failed to copy tempBuffer to device");

    err = cudaMemcpyToSymbol(d_kernelMat, kernelMat, sizeof(kernelMat));
    checkCudaError(err, "Failed to copy kernel matrix to constant memory");

    printf("Grid Size: (%d, %d), Block Size: (%d, %d)\n", gridSizeX, gridSizeY, blockDimX, blockDimY);

    cudaMethodRunner("Green Extraction", greenExtract_kernel, dim3(gridSizeX, gridSizeY), dim3(blockDimX, blockDimY),
                        d_tempBuffer, d_gImage, width, height, stride);

    // cudaMemoryDebug(d_gImage, width * height * sizeof(unsigned char), "d_gImage");
    // // Debugging: Print the last 30 bytes of the original image buffer
    // cudaMemoryDebug(d_tempBuffer, height * stride * sizeof(unsigned char), "d_tempBuffer");

    cudaMethodRunner("Red Blue and IR Extraction", redblueIRExtract_kernel, dim3(rbGridSizeX, rbGridSizeY), dim3(blockDimX, blockDimY),
                        d_tempBuffer, d_rImage, d_bImage, d_irImage, halfWidth, halfHeight, stride);

    cudaMethodRunner("Convolution Green", convolution_kernel, dim3(gridSizeX, gridSizeY), dim3(blockDimX, blockDimY),
                        d_gImage, d_gImage, width, height);

    cudaMethodRunner("Convolution Red", convolution_kernel, dim3(rbGridSizeX, rbGridSizeY), dim3(blockDimX, blockDimY),
                        d_rImage, d_rImage, halfWidth, halfHeight);

    cudaMethodRunner("Convolution Blue", convolution_kernel, dim3(rbGridSizeX, rbGridSizeY), dim3(blockDimX, blockDimY),
                        d_bImage, d_bImage, halfWidth, halfHeight);

    cudaMethodRunner("Bilinear Interpolation", bilinear_interpolate_kernel, dim3(gridSizeX, gridSizeY), dim3(blockDimX, blockDimY),
                        d_rImage, d_bImage, d_resized_rImage, d_resized_bImage, width, height, 2.0f, 2.0f);
    
    cudaMethodRunner("Combine RGB", combine_rgb_kernel, dim3(gridSizeX, gridSizeY), dim3(blockDimX, blockDimY),
                        d_resized_rImage, d_gImage, d_resized_bImage, d_rgbImage, width, height);
    cudaMethodRunner("Balance RGB", balance_rgb_kernel, dim3(gridSizeX, gridSizeY), dim3(blockDimX, blockDimY),
                        d_rgbImage, width, height, rGain, gGain, bGain);

    // cudaMethodRunner("Flip RGB Image", flip_image_kernel, dim3(gridSizeX, gridSizeY), dim3(blockDimX, blockDimY),
    //                     d_rgbImage, width, height, 3);
    // cudaMethodRunner("Flip IR Image", flip_image_kernel, dim3(gridSizeX, gridSizeY), dim3(blockDimX, blockDimY),
    //                     d_irImage, halfWidth, halfHeight, 1);

    err = cudaMemcpy(irImage, d_irImage, halfWidth * halfHeight * sizeof(unsigned char), cudaMemcpyDeviceToHost);
    checkCudaError(err, "Failed to copy irImage to host");
    err = cudaMemcpy(rgbImage, d_rgbImage, width * height * 3 * sizeof(unsigned char), cudaMemcpyDeviceToHost);
    checkCudaError(err, "Failed to copy rgbImage to host");
    cudaDeviceSynchronize();

    cudaFree(d_tempBuffer);
    cudaFree(d_irImage);
    cudaFree(d_rImage);
    cudaFree(d_gImage);
    cudaFree(d_bImage);
    cudaFree(d_resized_rImage);
    cudaFree(d_resized_bImage);
    cudaFree(d_rgbImage);
}