#include <cuda_runtime.h>
#include <chrono>
#include <cstdio>
#include <algorithm>

constexpr float kernelMat[9] = {
    0.00f, 0.25f, 0.00f,
    0.25f, 1.00f, 0.25f,
    0.00f, 0.25f, 0.00f
};

__constant__ float d_kernelMat[9];
template <typename T>
__device__ T clamp(T value, T minVal, T maxVal) {
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

__global__ void greenExtract_kernel(const unsigned char* raw10, unsigned char* gImage, int width, int height, int stride) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x < width && y < height) {
        if (y % 2 == 0 && (x % 4 == 1 || x % 4 == 3)) { // Green pixel in Bayer pattern
            gImage[y * width + x] = raw10[y * stride + (x / 4) * 5 + x % 4];
        } else if (y % 2 == 1 && (x % 4 == 0 || x % 4 == 2)) { // Green pixel in Bayer pattern
            gImage[y * width + x] = raw10[(y + 1) * stride + (x / 4) * 5 + x % 4];
        } else {
            gImage[y * width + x] = 0; // Not a green pixel
        }
        // if (x < 30 && y == 0) {
        //     printf("raw10[%d, %d] = %d, gImage[%d, %d] = %d\n", x, y, raw10[y * stride + (x / 4) * 5 + x % 4], x, y, gImage[y * width + x]);
        // }
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
__global__ void resize_bilinear_kernel(const unsigned char* red, const unsigned char* blue, unsigned char* ret_red, unsigned char* ret_blue, int inputWidth, int inputHeight) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x >= inputWidth || y >= inputHeight) return;

    // Calculate the corresponding coordinates in the input image
    float srcX = x / 2.0f;
    float srcY = y / 2.0f;
    
    int x0 = static_cast<int>(floor(srcX));
    int x1 = max(0, min(x0 + 1, inputWidth - 1));
    int y0 = static_cast<int>(floor(srcY));
    int y1 = max(0, min(y0 + 1, inputHeight - 1));

    float xLerp = srcX - x0;
    float yLerp = srcY - y0;

    // Bilinear interpolation for red channel
    float redTop = (1.0f - xLerp) * (1.0f - yLerp) * red[y0 * inputWidth + x0] +
                   xLerp * (1.0f - yLerp) * red[y0 * inputWidth + x1] +
                   (1.0f - xLerp) * yLerp * red[y1 * inputWidth + x0] +
                   xLerp * yLerp * red[y1 * inputWidth + x1];
    float blueTop = (1.0f - xLerp) * (1.0f - yLerp) * blue[y0 * inputWidth + x0] +
                    xLerp * (1.0f - yLerp) * blue[y0 * inputWidth + x1] +
                    (1.0f - xLerp) * yLerp * blue[y1 * inputWidth + x0] +
                    xLerp * yLerp * blue[y1 * inputWidth + x1];
    ret_red[y * inputWidth  * 2 + x] = static_cast<unsigned char>(redTop + 0.5f);
    ret_blue[y * inputWidth  * 2 + x] = static_cast<unsigned char>(blueTop + 0.5f);
}
__global__ void combine_rgb_kernel(const unsigned char* red, const unsigned char* green, const unsigned char* blue, unsigned char* rgbImage, int width, int height) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    if (x >= width || y >= height) return;
    int idx = (y * width + x) * 3;
    rgbImage[idx] = red[y * width + x];
    rgbImage[idx + 1] = green[y * width + x];
    rgbImage[idx + 2] = blue[y * width + x];
}

void read_gpu() {
    int deviceCount = 0;
    cudaGetDeviceCount(&deviceCount);
    
    printf("Number of GPUs: %d\n", deviceCount);
    
    for (int i = 0; i < deviceCount; i++) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, i);
        
        printf("\n--- GPU %d ---\n", i);
        printf("Device Name: %s\n", prop.name);
        printf("Compute Capability: %d.%d\n", prop.major, prop.minor);
        printf("Total Global Memory: %.2f GB\n", (float)prop.totalGlobalMem / (1024 * 1024 * 1024));
        printf("Total Constant Memory: %zu KB\n", prop.totalConstMem / 1024);
        printf("Shared Memory Per Block: %zu KB\n", prop.sharedMemPerBlock / 1024);
        printf("Registers Per Block: %d\n", prop.regsPerBlock);
        printf("Max Threads Per Block: %d\n", prop.maxThreadsPerBlock);
        printf("Max Block Dimensions: (%d, %d, %d)\n", prop.maxThreadsDim[0], prop.maxThreadsDim[1], prop.maxThreadsDim[2]);
        printf("Max Grid Dimensions: (%d, %d, %d)\n", prop.maxGridSize[0], prop.maxGridSize[1], prop.maxGridSize[2]);
        printf("Memory Bus Width: %d bits\n", prop.memoryBusWidth);
        printf("Warp Size: %d\n", prop.warpSize);
        printf("Concurrent Kernels: %s\n", prop.concurrentKernels ? "Yes" : "No");
        printf("Integrated: %s\n", prop.integrated ? "Yes" : "No");
        printf("Can Map Host Memory: %s\n", prop.canMapHostMemory ? "Yes" : "No");
        printf("Multi-Processor Count: %d\n", prop.multiProcessorCount);
        printf("Max Texture 1D: %d\n", prop.maxTexture1D);
        printf("Max Texture 2D: (%d, %d)\n", prop.maxTexture2D[0], prop.maxTexture2D[1]);
        printf("Max Texture 3D: (%d, %d, %d)\n", prop.maxTexture3D[0], prop.maxTexture3D[1], prop.maxTexture3D[2]);
        printf("Shared Memory Per Multiprocessor: %zu KB\n", prop.sharedMemPerMultiprocessor / 1024);
        printf("Regs Per Multiprocessor: %d\n", prop.regsPerMultiprocessor);
        printf("Max Threads Per Multiprocessor: %d\n", prop.maxThreadsPerMultiProcessor);
        printf("L2 Cache Size: %d KB\n", prop.l2CacheSize / 1024);
        printf("global L1 Cache Size: %d KB\n", prop.globalL1CacheSupported);
        printf("Local L1 Cache Size: %d KB\n", prop.localL1CacheSupported);
        printf("Managed Memory: %d\n", prop.managedMemory);
    }
}

void checkCudaError(cudaError_t err, const char* msg) {
    if (err != cudaSuccess) {
        fprintf(stderr, "%s (error code %s)!\n", msg, cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}

void debugCudaMemory(const unsigned char* d_ptr, size_t size, const char* varName) {
    unsigned char* h_ptr = new unsigned char[size];
    cudaError_t err = cudaMemcpy(h_ptr, d_ptr, size, cudaMemcpyDeviceToHost);
    checkCudaError(err, "Failed to copy device memory to host for debugging");

    printf("Debugging device memory for %s:\n", varName);
    for (size_t i = 0; i < size; ++i) {
        printf("%02X ", h_ptr[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    printf("\n");

    delete[] h_ptr;
}
void image_processing(unsigned char* tempBuffer, int width, int height, int stride, unsigned char* irImage, unsigned char* rgbImage) {
    cudaError_t err = cudaSuccess;
    // Calculate grid and block sizes
    int blockSize = 256;
    int gridSizeX = (width + blockSize - 1) / blockSize;
    int gridSizeY = (height + blockSize - 1) / blockSize;
    int halfWidth = width / 2;
    int halfHeight = height / 2;
    int rbGridSizeX = (halfWidth + blockSize - 1) / blockSize;
    int rbGridSizeY = (halfHeight + blockSize - 1) / blockSize;
    // Allocate device memory
    unsigned char* d_tempBuffer = nullptr;
    unsigned char* d_irImage = nullptr;
    unsigned char* d_rImage = nullptr;
    unsigned char* d_gImage = nullptr;
    unsigned char* d_bImage = nullptr;
    unsigned char* d_resized_rImage = nullptr;
    unsigned char* d_resized_bImage = nullptr;
    unsigned char* d_rgbImage = nullptr;
    {
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
    }

    err = cudaMemcpy(d_tempBuffer, tempBuffer, height * stride, cudaMemcpyHostToDevice);
    checkCudaError(err, "Failed to copy tempBuffer to device");

    err = cudaMemcpyToSymbol(d_kernelMat, kernelMat, sizeof(kernelMat));
    checkCudaError(err, "Failed to copy kernel matrix to constant memory");

    printf("Starting image processing on GPU...\n");
    cudaDeviceSynchronize();
    
    // Debug parameters
#if 1
    printf("Image dimensions: %d x %d\n", width, height);
    printf("Stride: %d\n", stride);
    printf("Grid size for green extraction: (%d, %d)\n", gridSizeX, gridSizeY);
    printf("Grid size for red/blue extraction: (%d, %d)\n", rbGridSizeX, rbGridSizeY);
    printf("Block size: %d\n", blockSize);
#endif

    cudaMethodRunner("Green Extraction", greenExtract_kernel, dim3(gridSizeX, gridSizeY), dim3(blockSize), d_tempBuffer, d_gImage, width, height, stride);

    cudaMethodRunner("Red and Blue Extraction", redblueIRExtract_kernel, dim3(rbGridSizeX, rbGridSizeY), dim3(blockSize), d_tempBuffer, d_rImage, d_bImage, d_irImage, halfWidth, halfHeight, stride);

    cudaMethodRunner("Convolution Green", convolution_kernel, dim3(gridSizeX, gridSizeY), dim3(blockSize), d_gImage, d_gImage, width, height);

    cudaMethodRunner("Convolution Red", convolution_kernel, dim3(rbGridSizeX, rbGridSizeY), dim3(blockSize), d_rImage, d_rImage, halfWidth, halfHeight);

    cudaMethodRunner("Convolution Blue", convolution_kernel, dim3(rbGridSizeX, rbGridSizeY), dim3(blockSize), d_bImage, d_bImage, halfWidth, halfHeight);

    cudaMethodRunner("Resize Bilinear", resize_bilinear_kernel, dim3(rbGridSizeX, rbGridSizeY), dim3(blockSize), d_rImage, d_bImage, d_resized_rImage, d_resized_bImage, halfWidth, halfHeight);
    
    cudaMethodRunner("Combine RGB", combine_rgb_kernel, dim3(gridSizeX, gridSizeY), dim3(blockSize), d_resized_rImage, d_gImage, d_resized_bImage, d_rgbImage, width, height);

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