#include "image_processing.h"
#include <filesystem>
#include <iostream>
#include <string>
#include <memory_resource>
#include <wincodec.h>
#include <shellapi.h>

namespace {

bool save_png_wic(const std::filesystem::path& filePath,
                  const unsigned char* data,
                  int width,
                  int height,
                  int strideBytes,
                  const WICPixelFormatGUID& formatGuid) {
    if (data == nullptr || width <= 0 || height <= 0 || strideBytes <= 0) {
        return false;
    }

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool shouldUninitialize = SUCCEEDED(hr);
    if (hr == RPC_E_CHANGED_MODE) {
        hr = S_OK;
    }
    if (FAILED(hr)) {
        return false;
    }

    IWICImagingFactory* factory = nullptr;
    IWICBitmapEncoder* encoder = nullptr;
    IWICStream* stream = nullptr;
    IWICBitmapFrameEncode* frame = nullptr;
    IPropertyBag2* propertyBag = nullptr;

    hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) {
        hr = factory->CreateStream(&stream);
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to create WIC Imaging Factory." << std::endl;
    }
    if (SUCCEEDED(hr)) {
        hr = stream->InitializeFromFilename(filePath.wstring().c_str(), GENERIC_WRITE);
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to initialize WIC stream." << std::endl;
    }
    if (SUCCEEDED(hr)) {
        hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to create WIC encoder." << std::endl;
    }
    if (SUCCEEDED(hr)) {
        hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to initialize WIC encoder." << std::endl;
    }
    if (SUCCEEDED(hr)) {
        hr = encoder->CreateNewFrame(&frame, &propertyBag);
    }
    if (SUCCEEDED(hr)) {
        hr = frame->Initialize(propertyBag);
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to create WIC frame." << std::endl;
    }
    if (SUCCEEDED(hr)) {
        hr = frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height));
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to set WIC frame size." << std::endl;
    }

    WICPixelFormatGUID targetFormat = formatGuid;
    if (SUCCEEDED(hr)) {
        hr = frame->SetPixelFormat(&targetFormat);
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to set WIC frame pixel format." << std::endl;
    }

    if (SUCCEEDED(hr)) {
        hr = frame->WritePixels(static_cast<UINT>(height),
                                static_cast<UINT>(strideBytes),
                                static_cast<UINT>(strideBytes * height),
                                const_cast<BYTE*>(data));
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to write pixels to WIC frame." << std::endl;
    }
    if (SUCCEEDED(hr)) {
        hr = frame->Commit();
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to commit WIC frame." << std::endl;
    }
    if (SUCCEEDED(hr)) {
        hr = encoder->Commit();
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to commit WIC encoder." << std::endl;
    }

    if (propertyBag != nullptr) {
        propertyBag->Release();
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to release WIC property bag." << std::endl;
    }
    if (frame != nullptr) {
        frame->Release();
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to release WIC frame." << std::endl;
    }
    if (encoder != nullptr) {
        encoder->Release();
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to release WIC encoder." << std::endl;
    }
    if (stream != nullptr) {
        stream->Release();
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to release WIC stream." << std::endl;
    }
    if (factory != nullptr) {
        factory->Release();
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to release WIC factory." << std::endl;
    }
    if (shouldUninitialize) {
        CoUninitialize();
    } else {
        hr = E_FAIL;
        std::cerr << "Failed to uninitialize COM." << std::endl;
    }

    return SUCCEEDED(hr);
}

bool open_with_default_app(const std::filesystem::path& filePath) {
    const std::wstring path = filePath.wstring();
    HINSTANCE result = ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<INT_PTR>(result) > 32;
}

} // namespace

constexpr int IMAGE_WIDTH = 2592;
constexpr int IMAGE_HEIGHT = 1944;
constexpr int STRIDE = IMAGE_WIDTH * 5 / 4; // Each 4 pixels in RAW10 take 5 bytes
constexpr int IMAGE_WIDTH_IN_BYTES = ((STRIDE + 15) / 16) * 16; // 16-byte aligned row stride
constexpr char INPUT_FILE[] = "image/frame_6506.raw";

int main(int argc, char** argv) {
    read_gpu();

    float rGain = 1.0f;
    float gGain = 1.0f;
    float bGain = 1.0f;

    if (argc == 4) {
        rGain = std::stof(argv[1]);
        gGain = std::stof(argv[2]);
        bGain = std::stof(argv[3]);
    } else if (argc != 1) {
        std::cerr << "Usage: " << argv[0] << " [rGain gGain bGain]" << std::endl;
        return 1;
    }
    std::ifstream inputFile(INPUT_FILE, std::ios::binary);
    if (!inputFile) {
        std::cerr << "Failed to open input file." << std::endl;
        return 1;
    }

    std::pmr::vector<unsigned char> irImage(IMAGE_WIDTH * IMAGE_HEIGHT / 4);
    std::pmr::vector<unsigned char> rgbImage(IMAGE_WIDTH * IMAGE_HEIGHT * 3);
    std::pmr::vector<unsigned char> tempBuffer(IMAGE_HEIGHT * IMAGE_WIDTH_IN_BYTES);

    inputFile.read(reinterpret_cast<char*>(tempBuffer.data()), tempBuffer.size());

    image_processing(tempBuffer.data(), IMAGE_WIDTH, IMAGE_HEIGHT, IMAGE_WIDTH_IN_BYTES, irImage.data(), rgbImage.data(), rGain, gGain, bGain);
    std::cout << "Image processing completed." << std::endl;

    std::filesystem::path outputDir = "image";
    std::filesystem::create_directory(outputDir);
    std::filesystem::path irOutputFile = outputDir / "ir_image.png";
    std::filesystem::path rgbOutputFile = outputDir / "rgb_image.png";

    if (!save_png_wic(irOutputFile,
                      irImage.data(),
                      IMAGE_WIDTH / 2,
                      IMAGE_HEIGHT / 2,
                      IMAGE_WIDTH / 2,
                      GUID_WICPixelFormat8bppGray)) {
        std::cerr << "Failed to write IR PNG file." << std::endl;
        return 1;
    }

    if (!save_png_wic(rgbOutputFile,
                      rgbImage.data(),
                      IMAGE_WIDTH,
                      IMAGE_HEIGHT,
                      IMAGE_WIDTH * 3,
                      GUID_WICPixelFormat24bppRGB)) {
        std::cerr << "Failed to write RGB PNG file." << std::endl;
        return 1;
    }

    if (!open_with_default_app(irOutputFile)) {
        std::cerr << "Warning: failed to open IR image in default viewer." << std::endl;
    }
    if (!open_with_default_app(rgbOutputFile)) {
        std::cerr << "Warning: failed to open RGB image in default viewer." << std::endl;
    }

    return 0;
}