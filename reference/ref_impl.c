#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"

#define STB_IMAGE_RESIZE2_IMPLEMENTATION
#include "stb_image_resize2.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// Wrapper functions for Zig interop

// Load PNG from file
unsigned char* stb_load_png(const char* filename, int* width, int* height, int* channels) {
    return stbi_load(filename, width, height, channels, 0);
}

// Load PNG from memory
unsigned char* stb_load_png_from_memory(const unsigned char* buffer, int len, int* width, int* height, int* channels) {
    return stbi_load_from_memory(buffer, len, width, height, channels, 0);
}

// Free image data
void stb_free(unsigned char* data) {
    stbi_image_free(data);
}

// Encode PNG to memory
unsigned char* stb_write_png_to_mem(const unsigned char* pixels, int w, int h, int channels, int* out_len) {
    return stbi_write_png_to_mem(pixels, w * channels, w, h, channels, out_len);
}

// Free write output (allocated by STBIW_MALLOC)
void stb_write_free(void* data) {
    STBIW_FREE(data);
}

// Resize image
unsigned char* stb_resize(const unsigned char* input_pixels, int input_w, int input_h,
                          int output_w, int output_h, int num_channels) {
    unsigned char* output = (unsigned char*)malloc(output_w * output_h * num_channels);
    if (!output) return NULL;

    stbir_resize_uint8_linear(input_pixels, input_w, input_h, 0,
                              output, output_w, output_h, 0,
                              (stbir_pixel_layout)num_channels);
    return output;
}
