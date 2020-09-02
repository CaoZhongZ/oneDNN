#pragma once

extern "C" {
void copy_1d_simd(
        float *dst, const float *src, int start_off, int src_width, int nelem);
void copy_1d_simd_c_unroll_4(float *dst, int d_stride, const float *src,
        int s_stride, int start_off, int src_width, int nelem);
void copy_1d_simd_c_unroll_8(float *dst, int d_stride, const float *src,
        int s_stride, int start_off, int src_width, int nelem);

void zero_1d_simd(float *dst, int nelem);
void zero_1d_simd_c_unroll_4(float *dst, int stride, int nelem);
void zero_1d_simd_c_unroll_8(float *dst, int stride, int nelem);
};
