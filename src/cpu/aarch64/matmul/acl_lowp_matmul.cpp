/*******************************************************************************
* Copyright 2024-2025 Arm Ltd. and affiliates
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*******************************************************************************/

#include "cpu/aarch64/matmul/acl_lowp_matmul.hpp"
#include "cpu/cpu_primitive.hpp"

namespace dnnl {
namespace impl {
namespace cpu {
namespace aarch64 {
namespace matmul {

namespace {
// Keys are anonymous. So deduce the type automagically.
using lowp_matmul_key_t = decltype(memory_tracking::names::key_gemm_tmp_buffer);

const std::vector<lowp_matmul_key_t> lowp_matmul_keys = {
        memory_tracking::names::key_gemm_asm_tmp_buffer,
        memory_tracking::names::key_gemm_pretranspose_b,
        memory_tracking::names::key_gemm_pretranspose,
        memory_tracking::names::key_conv_gemm_col,
        memory_tracking::names::key_conv_gemm_row,
        memory_tracking::names::key_gemm_blocked_a,
        memory_tracking::names::key_gemm_blocked_b,
        memory_tracking::names::key_gemm_mm_result_s32,
        memory_tracking::names::key_gemm_mm_signed_a,
        memory_tracking::names::key_gemm_mm_signed_output,
};
} // namespace
status_t acl_lowp_matmul_t::pd_t::init(engine_t *engine) {
    VDISPATCH_MATMUL(set_default_formats(), "failed to set default formats");
    using smask_t = primitive_attr_t::skip_mask_t;
    VDISPATCH_MATMUL(attr()->has_default_values(smask_t::scales
                             | smask_t::zero_points | smask_t::post_ops),
            "only scale, zero point and post-ops attrs supported");
    VDISPATCH_MATMUL(is_dense_format_kind(), VERBOSE_UNSUPPORTED_SPARSE_CFG);

    static const std::vector<int> supported_args {
            DNNL_ARG_SRC, DNNL_ARG_WEIGHTS, DNNL_ARG_DST};
    for (int arg : supported_args) {
        if (attr()->scales_.has_default_values(arg)) continue;

        VDISPATCH_MATMUL(attr()->scales_.get_mask(arg) == 0,
                VERBOSE_UNSUPPORTED_SCALES_CFG);
    }

    for (int arg : supported_args) {
        if (attr()->zero_points_.has_default_values(arg)) continue;

        VDISPATCH_MATMUL(attr()->zero_points_.get_mask(arg) == 0,
                VERBOSE_UNSUPPORTED_SCALES_CFG);
    }

    VDISPATCH_MATMUL(
            !has_runtime_dims_or_strides(), VERBOSE_RUNTIMEDIM_UNSUPPORTED);

    const memory_desc_wrapper src_d(src_md_);
    const memory_desc_wrapper wei_d(weights_md_);
    const memory_desc_wrapper bia_d(bias_md_);
    const memory_desc_wrapper dst_d(dst_md_);

    cpu::matmul::matmul_helper_t helper(src_d, wei_d, dst_d);
    const dim_t M = helper.M();
    const dim_t N = helper.N();
    const dim_t K = helper.K();
    const dim_t dst_batch = helper.batch();
    const dim_t src_batch = helper.src_batch();
    const dim_t wei_batch = helper.wei_batch();

    using namespace data_type;

    // Note that has_default_values checks the argument for default zero
    // points but skips the argument for scales. Hence they are the
    // opposite but mean similar things
    VDISPATCH_MATMUL(!(dst_d.data_type() == f32
                             && !(attr()->scales_.has_default_values(
                                          {DNNL_ARG_SRC, DNNL_ARG_WEIGHTS})
                                     && attr()->zero_points_.has_default_values(
                                             DNNL_ARG_DST))),
            "scale and zero-point for f32 dst unsupported");

    VDISPATCH_MATMUL(src_d.data_type() == s8 && wei_d.data_type() == s8
                    && utils::one_of(dst_d.data_type(), f32, s8)
                    && utils::one_of(bia_d.data_type(), f32, undef),
            VERBOSE_UNSUPPORTED_DT_CFG);
    almc_.dst_is_s8 = dst_d.data_type() == s8;

    // reject in case the op is running on a cpu that have i8mm instruction set.
    // this is a temporary fix until the issue is resolved.
    VDISPATCH_MATMUL(
            arm_compute::CPUInfo::get().has_i8mm() || dst_d.data_type() != s8,
            "Op not supported on CPUs without i8mm instructions when dest "
            "datatype is s8");

    using namespace format_tag;
    auto src_tag = memory_desc_matches_one_of_tag(src_md_, abcd, abc, ab);
    auto wei_tag = memory_desc_matches_one_of_tag(weights_md_, abcd, abc, ab);
    auto dst_tag = memory_desc_matches_one_of_tag(dst_md_, abcd, abc, ab);

    ACL_CHECK_SUPPORT(
            utils::one_of(format_tag::undef, src_tag, wei_tag, dst_tag),
            "Format tag is undefined");

    VDISPATCH_MATMUL_SC(memory_desc_init_by_tag(bias_md_, bias_md_.ndims,
                                bias_md_.dims, bias_md_.data_type, dst_tag),
            VERBOSE_UNSUPPORTED_BIAS_CFG);

    // We set the QuantizationInfo to be dynamic because it is re-set in run()
    almc_.src_tensor_info = arm_compute::TensorInfo(
            arm_compute::TensorShape(K, M, 1, src_batch), 1,
            arm_compute::DataType::QASYMM8_SIGNED,
            arm_compute::QuantizationInfo(1.0, 0, true));
    almc_.src_tensor_info.set_are_values_constant(false);

    almc_.wei_tensor_info
            = arm_compute::TensorInfo(arm_compute::TensorShape(N, K, wei_batch),
                    1, arm_compute::DataType::QASYMM8_SIGNED,
                    arm_compute::QuantizationInfo(1.0, 0, true));

    almc_.wei_tensor_info.set_are_values_constant(
            false); // disables persistent aux memory

    almc_.bia_tensor_info = arm_compute::TensorInfo(
            arm_compute::TensorShape(), 1, arm_compute::DataType::F32);
    almc_.with_bias = bia_d.format_kind() != format_kind::undef;

    if (almc_.with_bias) {
        switch (bia_d.ndims()) {
            case 2:
                VDISPATCH_MATMUL(bia_d.dims()[0] == 1 && bia_d.dims()[1] == N,
                        "Only 1xN bias is supported for 2D input");
                almc_.bia_tensor_info.set_tensor_shape(
                        arm_compute::TensorShape(bia_d.dims()[1], 1));
                break;
            case 3:
                VDISPATCH_MATMUL(bia_d.dims()[0] == 1 && bia_d.dims()[1] == 1
                                && bia_d.dims()[2] == N,
                        "Only 1x1xN bias is supported for 3D input");
                almc_.bia_tensor_info.set_tensor_shape(
                        arm_compute::TensorShape(bia_d.dims()[2], 1, 1));
                break;
            case 4:
                VDISPATCH_MATMUL(bia_d.dims()[0] == 1 && bia_d.dims()[1] == 1
                                && bia_d.dims()[2] == 1 && bia_d.dims()[3] == N,
                        "Only 1x1x1xN bias is supported for 4D input");
                almc_.bia_tensor_info.set_tensor_shape(
                        arm_compute::TensorShape(bia_d.dims()[3], 1, 1, 1));
                break;
        }
    }

    // We can fuse sum if it is the first post op
    if (attr_.post_ops_.contain(primitive_kind::sum, 0)) {
        // Check there isn't another sum after the first
        VDISPATCH_MATMUL(attr_.post_ops_.find(primitive_kind::sum, 1, -1) < 0,
                "cannot contain multiple sum post-ops");
        VDISPATCH_MATMUL(attr_.post_ops_.entry_[0].sum.scale == 1.0f,
                "sum post op scale must be 1 (no scale)");
        VDISPATCH_MATMUL(attr_.post_ops_.entry_[0].sum.zero_point == 0,
                "sum post op zero point must be 0 (no shift)");
        almc_.gemm_info.set_accumulate(true);
        almc_.sum_is_fused = true;
        almc_.use_dst_acc = almc_.dst_is_s8;
    } else {
        const bool contains_sum
                = attr_.post_ops_.find(primitive_kind::sum, 0, -1) >= 0;
        // When sum is not fused we need to use an intermediate accumulator
        // tensor to store the result of the matmul. This is also the case for
        // when dst is s8, since we perform s8:s8:f32 matmul. If both are true,
        // we need to use another temporary tensor to cast existing s8 dst data
        // to f32 so we can perform the unfused sum.
        almc_.use_dst_acc = contains_sum || almc_.dst_is_s8;
        almc_.use_cast_acc = contains_sum && almc_.dst_is_s8;
    }

    // Even if dst is s8, we do the post ops in f32
    memory_desc_t post_ops_default_md = dst_md_;
    post_ops_default_md.data_type = f32;
    CHECK(acl_post_ops.init(engine, attr_.post_ops_, post_ops_default_md,
            almc_.gemm_info.accumulate() ? 1 : 0));

    almc_.dst_tensor_info = arm_compute::TensorInfo(
            arm_compute::TensorShape(N, M, 1, dst_batch),
            arm_compute::Format::F32);

    almc_.dst_cast_tensor_info = almc_.dst_tensor_info;

    almc_.dst_s8_tensor_info = arm_compute::TensorInfo(
            arm_compute::TensorShape(N, M, 1, dst_batch), 1,
            arm_compute::DataType::QASYMM8_SIGNED,
            arm_compute::QuantizationInfo(1.0, 0, true));

    ACL_CHECK_VALID(arm_compute::experimental::op::CpuGEMMLowp::validate(
            &almc_.src_tensor_info, &almc_.wei_tensor_info,
            almc_.with_bias ? &almc_.bia_tensor_info : nullptr,
            &almc_.dst_tensor_info, almc_.gemm_info));

    if (almc_.dst_is_s8) {
        if (almc_.sum_is_fused) {
            ACL_CHECK_VALID(
                    arm_compute::experimental::op::CpuDequantize::validate(
                            &almc_.dst_s8_tensor_info, &almc_.dst_tensor_info));
        } else if (almc_.use_cast_acc) {
            ACL_CHECK_VALID(
                    arm_compute::experimental::op::CpuDequantize::validate(
                            &almc_.dst_s8_tensor_info,
                            &almc_.dst_cast_tensor_info));
        }
        ACL_CHECK_VALID(arm_compute::experimental::op::CpuQuantize::validate(
                &almc_.dst_tensor_info, &almc_.dst_s8_tensor_info));
    }
    arm_compute::experimental::op::CpuGEMMLowp gemm;
    gemm.configure(&almc_.src_tensor_info, &almc_.wei_tensor_info,
            almc_.with_bias ? &almc_.bia_tensor_info : nullptr,
            &almc_.dst_tensor_info, almc_.gemm_info);

    auto aux_mem_req = gemm.workspace();
    // quantization/dequantization layer has empty workspace.
    auto scratchpad = scratchpad_registry().registrar();
    CHECK(init_scratchpad(scratchpad, aux_mem_req));

    return status::success;
}

status_t acl_lowp_matmul_t::pd_t::init_scratchpad(
        memory_tracking::registrar_t &scratchpad,
        const arm_compute::experimental::MemoryRequirements &aux_mem_req) {

    if (aux_mem_req.size() != 0) {
        for (size_t id = 0; id < lowp_matmul_keys.size(); id++) {
            if (aux_mem_req[id].size > 0) {
                scratchpad.book(lowp_matmul_keys[id], aux_mem_req[id].size, 1,
                        aux_mem_req[id].alignment, aux_mem_req[id].alignment);
            }
        }
    }

    const memory_desc_wrapper dst_d(&dst_md_);
    if (almc_.use_dst_acc) {
        scratchpad.book(memory_tracking::names::key_matmul_dst_in_acc_dt,
                dst_d.nelems(), sizeof(float32_t));
    }
    if (almc_.use_cast_acc) {
        scratchpad.book(memory_tracking::names::key_matmul_dst_cast_acc,
                dst_d.nelems(), sizeof(float32_t));
    }
    return status::success;
}

status_t acl_lowp_matmul_t::init(engine_t *engine) {
    auto almc = pd()->almc_;

    gemm_ = std::make_unique<arm_compute::experimental::op::CpuGEMMLowp>();
    gemm_->configure(&almc.src_tensor_info, &almc.wei_tensor_info,
            almc.with_bias ? &almc.bia_tensor_info : nullptr,
            &almc.dst_tensor_info, almc.gemm_info);

    if (almc.dst_is_s8) {
        if (almc.sum_is_fused) {
            dequant_ = std::make_unique<
                    arm_compute::experimental::op::CpuDequantize>();
            dequant_->configure(
                    &almc.dst_s8_tensor_info, &almc.dst_tensor_info);
        }
        if (almc.use_cast_acc) {
            quant_ = std::make_unique<
                    arm_compute::experimental::op::CpuQuantize>();
            dequant_ = std::make_unique<
                    arm_compute::experimental::op::CpuDequantize>();
            dequant_->configure(
                    &almc.dst_s8_tensor_info, &almc.dst_cast_tensor_info);

            quant_->configure(
                    &almc.dst_cast_tensor_info, &almc.dst_s8_tensor_info);
        } else {
            quant_ = std::make_unique<
                    arm_compute::experimental::op::CpuQuantize>();
            quant_->configure(&almc.dst_tensor_info, &almc.dst_s8_tensor_info);
        }
    }

    return status::success;
}

status_t acl_lowp_matmul_t::execute(const exec_ctx_t &ctx) const {
    std::lock_guard<std::mutex> _lock {this->mtx_};
    const auto scratchpad = ctx.get_scratchpad_grantor();

    auto alcm = pd()->almc_;
    bool with_bias = pd()->almc_.with_bias;

    DEFINE_ARG_SCALES_BUFFER(src_scale, DNNL_ARG_SRC);
    DEFINE_ARG_SCALES_BUFFER(wei_scale, DNNL_ARG_WEIGHTS);
    DEFINE_ARG_SCALES_BUFFER(dst_scale, DNNL_ARG_DST);

    const int32_t *src_zero_points = CTX_IN_MEM(
            const int32_t *, DNNL_ARG_ATTR_ZERO_POINTS | DNNL_ARG_SRC);
    const int32_t *wei_zero_points = CTX_IN_MEM(
            const int32_t *, DNNL_ARG_ATTR_ZERO_POINTS | DNNL_ARG_WEIGHTS);
    const int32_t *dst_zero_points = CTX_IN_MEM(
            const int32_t *, DNNL_ARG_ATTR_ZERO_POINTS | DNNL_ARG_DST);

    const int32_t src_zero_point = src_zero_points ? src_zero_points[0] : 0;
    const int32_t wei_zero_point = wei_zero_points ? wei_zero_points[0] : 0;
    const int32_t dst_zero_point = dst_zero_points ? dst_zero_points[0] : 0;

    arm_compute::Tensor src_tensor, dst_tensor, wei_tensor, bia_tensor,
            dst_cast_tensor, dst_s8_tensor;
    auto src = CTX_IN_MEM(const int8_t *, DNNL_ARG_SRC);
    src_tensor.allocator()->init(alcm.src_tensor_info);
    src_tensor.allocator()->import_memory(const_cast<int8_t *>(src));

    auto wei = CTX_IN_MEM(const int8_t *, DNNL_ARG_WEIGHTS);
    wei_tensor.allocator()->init(alcm.wei_tensor_info);
    wei_tensor.allocator()->import_memory(const_cast<int8_t *>(wei));

    if (with_bias) {
        auto bias = CTX_IN_MEM(const float *, DNNL_ARG_BIAS);
        bia_tensor.allocator()->init(alcm.bia_tensor_info);
        bia_tensor.allocator()->import_memory(const_cast<float *>(bias));
    }

    auto dst = pd()->almc_.use_dst_acc ? scratchpad.get<void>(
                       memory_tracking::names::key_matmul_dst_in_acc_dt)
                                       : CTX_OUT_MEM(float *, DNNL_ARG_DST);
    dst_tensor.allocator()->init(alcm.dst_tensor_info);
    dst_tensor.allocator()->import_memory(dst);

    auto dst_cast = pd()->almc_.use_cast_acc ? scratchpad.get<void>(
                            memory_tracking::names::key_matmul_dst_cast_acc)
                                             : nullptr;
    if (dst_cast) {
        dst_cast_tensor.allocator()->init(alcm.dst_cast_tensor_info);
        dst_cast_tensor.allocator()->import_memory(dst_cast);
    }

    if ((pd()->almc_.dst_is_s8 && pd()->almc_.sum_is_fused) || dst_cast) {
        auto dst_s8 = CTX_OUT_MEM(int8_t *, DNNL_ARG_DST);
        dst_s8_tensor.allocator()->init(alcm.dst_s8_tensor_info);
        dst_s8_tensor.allocator()->import_memory(const_cast<int8_t *>(dst_s8));
        // oneDNN expects all intermediate operations to be performed
        // before taking dst scale and offset into account
        dst_s8_tensor.info()->set_quantization_info(
                arm_compute::QuantizationInfo(1, 0, true));

        arm_compute::ITensorPack pack;
        pack.add_tensor(arm_compute::TensorType::ACL_SRC, &dst_s8_tensor);
        pack.add_tensor(arm_compute::TensorType::ACL_DST, &dst_tensor);
        dequant_->run(pack);
    }

    // Note that we set the offset to be -zero_point, this is a known
    // inconsistency with most other operators in the ACL API
    src_tensor.info()->set_quantization_info(
            arm_compute::QuantizationInfo(*src_scale, -src_zero_point, true));

    wei_tensor.info()->set_quantization_info(
            arm_compute::QuantizationInfo(*wei_scale, -wei_zero_point, true));

    arm_compute::ITensorPack gemm_pack {
            {arm_compute::TensorType::ACL_SRC_0, &src_tensor},
            {arm_compute::TensorType::ACL_SRC_1, &wei_tensor},
            {arm_compute::TensorType::ACL_DST, &dst_tensor}};

    if (with_bias) {
        gemm_pack.add_tensor(arm_compute::TensorType::ACL_SRC_2, &bia_tensor);
    }

    // Hold onto tmp tensors while we need pack.
    auto aux_mem = gemm_->workspace();
    std::vector<arm_compute::Tensor> tmp_tensors(aux_mem.size());
    for (size_t id = 0; id < lowp_matmul_keys.size(); id++) {
        if (aux_mem[id].size > 0) {
            const auto info = arm_compute::TensorInfo(
                    arm_compute::TensorShape(aux_mem[id].size), 1,
                    arm_compute::DataType::U8);
            auto buffer = scratchpad.get<void>(lowp_matmul_keys[id]);
            tmp_tensors[id].allocator()->init(info, aux_mem[id].alignment);
            tmp_tensors[id].allocator()->import_memory(buffer);
            gemm_pack.add_tensor(aux_mem[id].slot, &tmp_tensors[id]);
        }
    }
    gemm_->run(gemm_pack);

    auto src_post_ops = dst_tensor.buffer();
    // Here we select the output destination for post-ops. By default,
    // these are in-place so that dst=src. However, when there is a non-fused
    // sum, we set dst to be the tensor where data to be summed is stored.
    void *dst_post_ops;
    if (pd()->acl_post_ops.has_sum() && !pd()->almc_.sum_is_fused) {
        if (pd()->almc_.dst_is_s8) {
            dst_post_ops = dst_cast_tensor.buffer();
        } else {
            dst_post_ops = CTX_OUT_MEM(void *, DNNL_ARG_DST);
        }
    } else {
        dst_post_ops = src_post_ops;
    }
    pd()->acl_post_ops.execute(ctx, src_post_ops, dst_post_ops);

    // free() here tells ACL it can no longer use it, it does not deallocate
    src_tensor.allocator()->free();
    wei_tensor.allocator()->free();
    if (with_bias) { bia_tensor.allocator()->free(); }

    if (pd()->almc_.dst_is_s8) {
        auto dst_s8 = CTX_OUT_MEM(int8_t *, DNNL_ARG_DST);
        dst_s8_tensor.allocator()->init(alcm.dst_s8_tensor_info);
        dst_s8_tensor.allocator()->import_memory(const_cast<int8_t *>(dst_s8));
        dst_s8_tensor.info()->set_quantization_info(
                arm_compute::QuantizationInfo(
                        1.0 / (*dst_scale), dst_zero_point, true));
        arm_compute::ITensorPack pack;
        pack.add_tensor(arm_compute::TensorType::ACL_SRC, &dst_tensor);
        pack.add_tensor(arm_compute::TensorType::ACL_DST, &dst_s8_tensor);
        quant_->run(pack);
        dst_s8_tensor.allocator()->free();
    }

    dst_tensor.allocator()->free();

    return status::success;
};

} // namespace matmul
} // namespace aarch64
} // namespace cpu
} // namespace impl
} // namespace dnnl
