//
// dst: destination address, relative to actual line start, no padding
// considered src: source address, absolute address to actual line start,
// possible out of bound access
//
export void copy_1d_simd(float *uniform dst, const float *uniform src,
        uniform int start_off, uniform int src_width, uniform int nelem) {
    for (int pid = programIndex; pid < nelem; pid += programCount) {
        int p_off = pid + start_off;
        dst[pid] = (p_off >= 0 && p_off < src_width) ? src[p_off] : 0;
    }
}

//
// stride: stride to next start of destination
// stride: stride to next start of source
//
export void copy_1d_simd_c_unroll_4(float *uniform dst, uniform int d_stride,
        const float *uniform src, uniform int s_stride, uniform int start_off,
        uniform int src_width, uniform int nelem) {
    for (int pid = programIndex; pid < nelem; pid += programCount) {
        int p_off = pid + start_off;
        for (uniform int unroll = 0; unroll < 4; ++unroll) {
            (dst + unroll * d_stride)[pid] = (p_off >= 0 && p_off < src_width)
                    ? (src + unroll * s_stride)[p_off]
                    : 0.;
        }
    }
}

//
// d_stride: stride to next start of destination
// s_stride: stride to next start of source
//
export void copy_1d_simd_c_unroll_8(float *uniform dst, uniform int d_stride,
        const float *uniform src, uniform int s_stride, uniform int start_off,
        uniform int src_width, uniform int nelem) {
    for (int pid = programIndex; pid < nelem; pid += programCount) {
        int p_off = pid + start_off;
        for (uniform int unroll = 0; unroll < 8; ++unroll) {
            (dst + unroll * d_stride)[pid] = (p_off >= 0 && p_off < src_width)
                    ? (src + unroll * s_stride)[p_off]
                    : 0.;
        }
    }
}

// zero 1d simd
export void zero_1d_simd(float *uniform dst, uniform int nelem) {
    for (int pid = programIndex; pid < nelem; pid += programCount) {
        dst[pid] = 0.;
    }
}

export void zero_1d_simd_c_unroll_4(
        float *uniform dst, uniform int stride, uniform int nelem) {
    for (int pid = programIndex; pid < nelem; pid += programCount) {
        for (uniform int unroll = 0; unroll < 4; ++unroll) {
            (dst + unroll * stride)[pid] = 0.;
        }
    }
}

export void zero_1d_simd_c_unroll_8(
        float *uniform dst, uniform int stride, uniform int nelem) {
    for (int pid = programIndex; pid < nelem; pid += programCount) {
        for (uniform int unroll = 0; unroll < 8; ++unroll) {
            (dst + unroll * stride)[pid] = 0.;
        }
    }
}
