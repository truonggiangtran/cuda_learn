#pragma once

#include <stdio.h>
#include <fstream>

void read_gpu();
void image_processing(unsigned char* tempBuffer, int width, int height, int stride, unsigned char* irImage = nullptr, unsigned char* rgbImage = nullptr, float rGain = 1.0f, float gGain = 1.0f, float bGain = 1.0f);