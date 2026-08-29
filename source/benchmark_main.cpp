#include "image_processing.h"

#include <cuda_runtime.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int IMAGE_WIDTH = 2592;
constexpr int IMAGE_HEIGHT = 1944;
constexpr int STRIDE = IMAGE_WIDTH * 5 / 4;
constexpr int IMAGE_WIDTH_IN_BYTES = ((STRIDE + 15) / 16) * 16;
constexpr const char* DEFAULT_INPUT_FILE = "image/frame_6506.raw";

struct Options {
    int warmups = 5;
    int iterations = 30;
    std::string inputFile = DEFAULT_INPUT_FILE;
    float rGain = 1.0f;
    float gGain = 1.0f;
    float bGain = 1.0f;
};

void check_cuda(cudaError_t error, const char* operation) {
    if (error != cudaSuccess) {
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(error));
    }
}

int parse_positive_int(const char* value, const char* optionName, bool allowZero) {
    const int parsed = std::stoi(value);
    if (parsed < 0 || (!allowZero && parsed == 0)) {
        throw std::invalid_argument(std::string(optionName) + " has invalid value");
    }
    return parsed;
}

Options parse_options(int argc, char** argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        auto require_value = [&](const char* optionName) -> const char* {
            if (++index >= argc) {
                throw std::invalid_argument(std::string(optionName) + " requires a value");
            }
            return argv[index];
        };

        if (argument == "--warmup") {
            options.warmups = parse_positive_int(require_value("--warmup"), "--warmup", true);
        } else if (argument == "--iterations") {
            options.iterations = parse_positive_int(require_value("--iterations"), "--iterations", false);
        } else if (argument == "--input") {
            options.inputFile = require_value("--input");
        } else if (argument == "--r-gain") {
            options.rGain = std::stof(require_value("--r-gain"));
        } else if (argument == "--g-gain") {
            options.gGain = std::stof(require_value("--g-gain"));
        } else if (argument == "--b-gain") {
            options.bGain = std::stof(require_value("--b-gain"));
        } else if (argument == "--help") {
            std::cout << "Usage: cuda_benchmark [--warmup N] [--iterations N] [--input PATH] "
                         "[--r-gain N] [--g-gain N] [--b-gain N]\n";
            std::exit(EXIT_SUCCESS);
        } else {
            throw std::invalid_argument("Unknown option: " + argument);
        }
    }
    return options;
}

std::uint64_t fnv1a64(const unsigned char* data, std::size_t size) {
    std::uint64_t hash = 14695981039346656037ULL;
    for (std::size_t index = 0; index < size; ++index) {
        hash ^= data[index];
        hash *= 1099511628211ULL;
    }
    return hash;
}

std::string hash_string(std::uint64_t hash) {
    std::ostringstream output;
    output << std::hex << std::setw(16) << std::setfill('0') << hash;
    return output.str();
}

double percentile(const std::vector<double>& sortedValues, double fraction) {
    const auto rank = static_cast<std::size_t>(
        std::ceil(fraction * static_cast<double>(sortedValues.size())));
    return sortedValues[std::max<std::size_t>(1, rank) - 1];
}

double mean(const std::vector<double>& values) {
    return std::accumulate(values.begin(), values.end(), 0.0) /
           static_cast<double>(values.size());
}

double standard_deviation(const std::vector<double>& values, double average) {
    double squaredDifferenceSum = 0.0;
    for (const double value : values) {
        const double difference = value - average;
        squaredDifferenceSum += difference * difference;
    }
    return std::sqrt(squaredDifferenceSum / static_cast<double>(values.size()));
}
} // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parse_options(argc, argv);
        constexpr std::size_t inputBytes = IMAGE_HEIGHT * IMAGE_WIDTH_IN_BYTES;
        constexpr std::size_t irBytes = IMAGE_WIDTH * IMAGE_HEIGHT / 4;
        constexpr std::size_t rgbBytes = IMAGE_WIDTH * IMAGE_HEIGHT * 3;

        std::vector<unsigned char> input(inputBytes);
        std::vector<unsigned char> irImage(irBytes);
        std::vector<unsigned char> rgbImage(rgbBytes);

        std::ifstream inputFile(options.inputFile, std::ios::binary);
        if (!inputFile) {
            throw std::runtime_error("Failed to open input file: " + options.inputFile);
        }
        inputFile.read(reinterpret_cast<char*>(input.data()), static_cast<std::streamsize>(input.size()));
        if (inputFile.gcount() != static_cast<std::streamsize>(input.size())) {
            throw std::runtime_error("Input file is smaller than expected RAW10 frame");
        }

        check_cuda(cudaSetDevice(0), "cudaSetDevice");
        check_cuda(cudaFree(nullptr), "CUDA context initialization");

        cudaDeviceProp device{};
        check_cuda(cudaGetDeviceProperties(&device, 0), "cudaGetDeviceProperties");
        int driverVersion = 0;
        int runtimeVersion = 0;
        check_cuda(cudaDriverGetVersion(&driverVersion), "cudaDriverGetVersion");
        check_cuda(cudaRuntimeGetVersion(&runtimeVersion), "cudaRuntimeGetVersion");

        auto process_frame = [&] {
            image_processing(input.data(),
                             IMAGE_WIDTH,
                             IMAGE_HEIGHT,
                             IMAGE_WIDTH_IN_BYTES,
                             irImage.data(),
                             rgbImage.data(),
                             options.rGain,
                             options.gGain,
                             options.bGain,
                             false);
        };

        for (int iteration = 0; iteration < options.warmups; ++iteration) {
            process_frame();
        }

        std::vector<double> durationsMs;
        durationsMs.reserve(static_cast<std::size_t>(options.iterations));
        bool deterministic = true;
        std::uint64_t expectedIrHash = 0;
        std::uint64_t expectedRgbHash = 0;

        for (int iteration = 0; iteration < options.iterations; ++iteration) {
            const auto start = std::chrono::steady_clock::now();
            process_frame();
            const auto stop = std::chrono::steady_clock::now();
            durationsMs.push_back(
                std::chrono::duration<double, std::milli>(stop - start).count());

            const std::uint64_t irHash = fnv1a64(irImage.data(), irImage.size());
            const std::uint64_t rgbHash = fnv1a64(rgbImage.data(), rgbImage.size());
            if (iteration == 0) {
                expectedIrHash = irHash;
                expectedRgbHash = rgbHash;
            } else if (irHash != expectedIrHash || rgbHash != expectedRgbHash) {
                deterministic = false;
            }
        }

        std::vector<double> sortedDurations = durationsMs;
        std::sort(sortedDurations.begin(), sortedDurations.end());
        const double averageMs = mean(durationsMs);
        const double medianMs = percentile(sortedDurations, 0.5);
        const double p95Ms = percentile(sortedDurations, 0.95);
        const double stddevMs = standard_deviation(durationsMs, averageMs);

        std::cout << std::fixed << std::setprecision(6);
        std::cout << "BENCHMARK_JSON={"
                  << "\"schema_version\":1,"
                  << "\"scope\":\"image_processing_end_to_end\","
                  << "\"warmup_iterations\":" << options.warmups << ','
                  << "\"measured_iterations\":" << options.iterations << ','
                  << "\"width\":" << IMAGE_WIDTH << ','
                  << "\"height\":" << IMAGE_HEIGHT << ','
                  << "\"input_bytes\":" << inputBytes << ','
                  << "\"output_bytes\":" << (irBytes + rgbBytes) << ','
                  << "\"mean_ms\":" << averageMs << ','
                  << "\"median_ms\":" << medianMs << ','
                  << "\"p95_ms\":" << p95Ms << ','
                  << "\"min_ms\":" << sortedDurations.front() << ','
                  << "\"max_ms\":" << sortedDurations.back() << ','
                  << "\"stddev_ms\":" << stddevMs << ','
                  << "\"throughput_fps\":" << (1000.0 / averageMs) << ','
                  << "\"deterministic\":" << (deterministic ? "true" : "false") << ','
                  << "\"ir_hash\":\"" << hash_string(expectedIrHash) << "\","
                  << "\"rgb_hash\":\"" << hash_string(expectedRgbHash) << "\","
                  << "\"gpu_name\":\"" << device.name << "\","
                  << "\"compute_capability\":\"" << device.major << '.' << device.minor << "\","
                  << "\"sm_count\":" << device.multiProcessorCount << ','
                  << "\"global_memory_bytes\":" << device.totalGlobalMem << ','
                  << "\"driver_version\":" << driverVersion << ','
                  << "\"runtime_version\":" << runtimeVersion << ','
                  << "\"r_gain\":" << options.rGain << ','
                  << "\"g_gain\":" << options.gGain << ','
                  << "\"b_gain\":" << options.bGain
                  << "}\n";

        if (!deterministic) {
            std::cerr << "Warning: output hashes changed between measured iterations.\n";
        }
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "Benchmark failed: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
