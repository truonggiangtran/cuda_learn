#include "image_processing.h"
#include <filesystem>
#include <iostream>
#include <string>
#include <memory_resource>

constexpr int IMAGE_WIDTH = 2592;
constexpr int IMAGE_HEIGHT = 1944;
constexpr int STRIDE = IMAGE_WIDTH * 5 / 4; // Each 4 pixels in RAW10 take 5 bytes
constexpr int IMAGE_WIDTH_IN_BYTES = ((STRIDE + 15) / 16) * 16; // 16-byte aligned row stride
constexpr char INPUT_FILE[] = "image/frame_6506.raw";

// pixel format of the input RAW image is RGB-Ir MIPI RAW10 format
/*
R   G   R   G   R   G   R   G   ...
G   Ir  G   Ir  G   Ir  G   Ir  ...
B   G   B   G   B   G   B   G   ...
G   Ir  G   Ir  G   Ir  G   Ir  ...
*/

int main(int argc, char** argv) {
    read_gpu();

    std::ifstream inputFile(INPUT_FILE, std::ios::binary);
    if (!inputFile) {
        std::cerr << "Failed to open input file." << std::endl;
        return 1;
    }

    std::pmr::vector<unsigned char> irImage(IMAGE_WIDTH * IMAGE_HEIGHT / 4);
    std::pmr::vector<unsigned char> rgbImage(IMAGE_WIDTH * IMAGE_HEIGHT * 3);
    std::pmr::vector<unsigned char> tempBuffer(IMAGE_HEIGHT * IMAGE_WIDTH_IN_BYTES);

    inputFile.read(reinterpret_cast<char*>(tempBuffer.data()), tempBuffer.size());
    // debug input buffer
    // for (int i = 0; i < 10; ++i) {
    //     std::cout << "tempBuffer[" << i << "] = " << static_cast<int>(tempBuffer[i]) << std::endl;
    // }
    image_processing(tempBuffer.data(), IMAGE_WIDTH, IMAGE_HEIGHT, IMAGE_WIDTH_IN_BYTES, irImage.data(), rgbImage.data());
    std::cout << "Image processing completed." << std::endl;

    std::filesystem::path outputDir = "image";
    std::filesystem::create_directory(outputDir);
    std::filesystem::path irOutputFile = outputDir / "ir_image.raw";
    std::filesystem::path rgbOutputFile = outputDir / "rgb_image.raw";

    std::ofstream irOutput(irOutputFile, std::ios::binary);
    if (!irOutput) {
        std::cerr << "Failed to open IR output file." << std::endl;
        return 1;
    }
    irOutput.write(reinterpret_cast<const char*>(irImage.data()), irImage.size());

    std::ofstream rgbOutput(rgbOutputFile, std::ios::binary);
    if (!rgbOutput) {
        std::cerr << "Failed to open RGB output file." << std::endl;
        return 1;
    }
    rgbOutput.write(reinterpret_cast<const char*>(rgbImage.data()), rgbImage.size());

    return 0;
}