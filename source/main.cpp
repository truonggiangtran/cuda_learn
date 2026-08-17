#include "image_processing.h"

#include <filesystem>
#include <iostream>
#include <memory_resource>
#include <string>

#include <opencv2/core/mat.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

namespace {
bool save_png(const std::filesystem::path& filePath,
              const unsigned char* data,
              int width,
              int height,
              int strideBytes,
              int channels) {
    if (data == nullptr || width <= 0 || height <= 0 || strideBytes <= 0) {
        return false;
    }

    const int type = channels == 1 ? CV_8UC1 : CV_8UC3;
    const cv::Mat image(height, width, type, const_cast<unsigned char*>(data), strideBytes);
    if (channels == 1) {
        return cv::imwrite(filePath.string(), image);
    }

    cv::Mat bgrImage;
    cv::cvtColor(image, bgrImage, cv::COLOR_RGB2BGR);
    return cv::imwrite(filePath.string(), bgrImage);
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

    image_processing(tempBuffer.data(),
                     IMAGE_WIDTH,
                     IMAGE_HEIGHT,
                     IMAGE_WIDTH_IN_BYTES,
                     irImage.data(),
                     rgbImage.data(),
                     rGain,
                     gGain,
                     bGain);
    std::cout << "Image processing completed." << std::endl;

    const std::filesystem::path outputDir = "image";
    std::filesystem::create_directory(outputDir);
    const std::filesystem::path irOutputFile = outputDir / "ir_image.png";
    const std::filesystem::path rgbOutputFile = outputDir / "rgb_image.png";

    const bool irSaved = save_png(irOutputFile,
                                  irImage.data(),
                                  IMAGE_WIDTH / 2,
                                  IMAGE_HEIGHT / 2,
                                  IMAGE_WIDTH / 2,
                                  1);
    const bool rgbSaved = save_png(rgbOutputFile,
                                   rgbImage.data(),
                                   IMAGE_WIDTH,
                                   IMAGE_HEIGHT,
                                   IMAGE_WIDTH * 3,
                                   3);

    if (!irSaved) {
        std::cerr << "Failed to write IR PNG file." << std::endl;
        return 1;
    }

    if (!rgbSaved) {
        std::cerr << "Failed to write RGB PNG file." << std::endl;
        return 1;
    }

    return 0;
}
