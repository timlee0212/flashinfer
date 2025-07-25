/*
 * Copyright (c) 2023 by FlashInfer team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <flashinfer/attention/mask.cuh>
#include <flashinfer/attention/scheduler.cuh>
#include <flashinfer/layout.cuh>
#include <flashinfer/math.cuh>
#include <optional>

#include "batch_prefill_sm90_config.inc"
#include "pytorch_conversion_utils.h"
#include "pytorch_extension_utils.h"

namespace flashinfer {

template <uint32_t HEAD_DIM, MaskMode MASK_MODE, bool LEFT_SLIDING_WINDOW,
          bool SAME_SCHEDULE_FOR_ALL_HEADS, typename AttentionVariant, typename Params>
cudaError_t BatchFP8PrefillWithPagedKVCacheDispatched(Params& params, bool enable_pdl,
                                                      cudaStream_t stream);

}  // namespace flashinfer

using namespace flashinfer;

at::Tensor BatchPrefillWithKVCacheSM90Plan(
    at::Tensor float_workspace_buffer, at::Tensor int_workspace_buffer,
    at::Tensor page_locked_int_workspace_buffer, at::Tensor qo_indptr, at::Tensor kv_indptr,
    at::Tensor kv_len_arr, int64_t total_num_rows, int64_t batch_size, int64_t num_qo_heads,
    int64_t num_kv_heads, int64_t page_size, bool enable_cuda_graph, int64_t head_dim_qk,
    int64_t head_dim_vo, bool causal) {
  size_t float_workspace_size_in_bytes =
      float_workspace_buffer.size(0) * float_workspace_buffer.element_size();
  size_t int_workspace_size_in_bytes =
      int_workspace_buffer.size(0) * int_workspace_buffer.element_size();

  flashinfer::PrefillPlanSM90Info plan_info;

  const c10::cuda::OptionalCUDAGuard device_guard(float_workspace_buffer.device());
  cudaStream_t stream = c10::cuda::getCurrentCUDAStream();

  cudaError_t status =
      PrefillSM90Plan(float_workspace_buffer.data_ptr(), float_workspace_size_in_bytes,
                      int_workspace_buffer.data_ptr(), page_locked_int_workspace_buffer.data_ptr(),
                      int_workspace_size_in_bytes, plan_info, qo_indptr.data_ptr<IdType>(),
                      kv_indptr.data_ptr<IdType>(), kv_len_arr.data_ptr<IdType>(), total_num_rows,
                      batch_size, num_qo_heads, num_kv_heads, head_dim_qk, head_dim_vo, page_size,
                      causal, enable_cuda_graph, /*sizeof_dtype_o=*/2, stream);

  TORCH_CHECK(status == cudaSuccess,
              "PrefillSM90Plan failed with error: ", cudaGetErrorString(status));

  return vec_to_tensor(plan_info.ToVector());
}

void BatchPrefillWithRaggedKVCacheSM90Run(at::Tensor float_workspace_buffer,
                                          at::Tensor int_workspace_buffer, at::Tensor plan_info_vec,
                                          at::Tensor q, at::Tensor k, at::Tensor v,
                                          at::Tensor qo_indptr, at::Tensor kv_indptr, at::Tensor o,
                                          std::optional<at::Tensor> maybe_lse,
                                          int64_t mask_mode_code, int64_t layout,
                                          int64_t window_left,
                                          bool enable_pdl  // placeholder
                                              ADDITIONAL_FUNC_PARAMS) {
  return;  // TODO: Implement this function
}

void BatchPrefillWithPagedKVCacheSM90Run(
    at::Tensor float_workspace_buffer, at::Tensor int_workspace_buffer, at::Tensor plan_info_vec,
    at::Tensor q, at::Tensor paged_k_cache, at::Tensor paged_v_cache, at::Tensor qo_indptr,
    at::Tensor paged_kv_indptr, at::Tensor paged_kv_indices, at::Tensor paged_kv_last_page_len,
    at::Tensor o, std::optional<at::Tensor> maybe_lse, int64_t mask_mode_code, int64_t layout,
    int64_t window_left, bool enable_pdl ADDITIONAL_FUNC_PARAMS) {
  PrefillPlanSM90Info plan_info;
  plan_info.FromVector(tensor_to_vec(plan_info_vec));

  if (maybe_lse) {
    const auto& lse = *maybe_lse;
    TORCH_CHECK(lse.size(0) == q.size(0), lse.size(0), q.size(0));
    TORCH_CHECK(lse.size(1) == q.size(1), lse.size(1), q.size(1));
  }
  QKVLayout kv_layout = static_cast<QKVLayout>(layout);
  int64_t num_kv_heads, page_size;
  int64_t head_dim_qk = q.size(2);
  int64_t head_dim_vo = paged_v_cache.size(3);
  if (kv_layout == QKVLayout::kHND) {
    num_kv_heads = paged_k_cache.size(1);
    page_size = paged_k_cache.size(2);
  } else {
    page_size = paged_k_cache.size(1);
    num_kv_heads = paged_k_cache.size(2);
  }

  void* float_buffer_ptr = float_workspace_buffer.data_ptr();
  void* int_buffer_ptr = int_workspace_buffer.data_ptr();

  auto q_scalar_type = q.scalar_type();
  auto kv_scalar_type = paged_k_cache.scalar_type();

  const c10::cuda::OptionalCUDAGuard device_guard(float_workspace_buffer.device());
  cudaStream_t stream = c10::cuda::getCurrentCUDAStream();
  const MaskMode mask_mode = static_cast<MaskMode>(mask_mode_code);
  bool use_swa = window_left != -1;

  DISPATCH_context(
      DTypeQ, DTypeKV, DTypeO, IdType, MASK_MODE, HEAD_DIM_QK, HEAD_DIM_VO, USE_SLIDING_WINDOW,
      USE_LOGITS_SOFT_CAP, AttentionVariant, RaggedParams, PagedParams, [&] {
        PagedParams params;

        params.q_ptr = static_cast<DTypeQ*>(q.data_ptr());
        params.k_ptr = static_cast<DTypeKV*>(paged_k_cache.data_ptr());
        params.v_ptr = static_cast<DTypeKV*>(paged_v_cache.data_ptr());
        params.o_ptr = static_cast<DTypeO*>(o.data_ptr());
        params.lse_ptr = maybe_lse ? static_cast<float*>(maybe_lse->data_ptr()) : nullptr;
        params.q_stride_n = q.stride(0);
        params.q_stride_h = q.stride(1);
        params.o_stride_n = o.stride(0);
        params.o_stride_h = o.stride(1);
        if (kv_layout == QKVLayout::kNHD) {
          // (num_pages, page_size, num_heads, head_dim)
          params.k_stride_n = paged_k_cache.stride(1);
          params.k_stride_h = paged_k_cache.stride(2);
          params.v_stride_n = paged_v_cache.stride(1);
          params.v_stride_h = paged_v_cache.stride(2);
        } else {
          // (num_pages, num_heads, page_size, head_dim)
          params.k_stride_h = paged_k_cache.stride(1);
          params.k_stride_n = paged_k_cache.stride(2);
          params.v_stride_h = paged_v_cache.stride(1);
          params.v_stride_n = paged_v_cache.stride(2);
        }
        params.nnz_qo = q.size(0);
        params.num_qo_heads = q.size(1);
        params.num_kv_heads = num_kv_heads;
        params.group_size = params.num_qo_heads / num_kv_heads;
        params.page_size = page_size;
        params.window_left = window_left;
        params.causal = mask_mode_code == 1;
        params.qo_tile_indices =
            GetPtrFromBaseOffset<IdType>(int_buffer_ptr, plan_info.qo_tile_indices_offset);
        params.qo_indptr = GetPtrFromBaseOffset<IdType>(int_buffer_ptr, plan_info.qo_indptr_offset);
        params.kv_indptr = GetPtrFromBaseOffset<IdType>(int_buffer_ptr, plan_info.kv_indptr_offset);
        params.qo_lens = GetPtrFromBaseOffset<IdType>(int_buffer_ptr, plan_info.qo_len_offset);
        params.kv_lens = GetPtrFromBaseOffset<IdType>(int_buffer_ptr, plan_info.kv_len_offset);
        params.batch_indices =
            GetPtrFromBaseOffset<IdType>(int_buffer_ptr, plan_info.batch_indices_offset);
        params.head_indices =
            GetPtrFromBaseOffset<IdType>(int_buffer_ptr, plan_info.head_indices_offset);
        params.work_indptr =
            GetPtrFromBaseOffset<IdType>(int_buffer_ptr, plan_info.work_indptr_offset);
        params.kv_indices = static_cast<IdType*>(paged_kv_indices.data_ptr());

        ADDITIONAL_PARAMS_SETTER

        // Not support various head_dim for now
        static_assert(HEAD_DIM_QK == HEAD_DIM_VO, "head_dim_qk and head_dim_vo should be the same");
        // Currently only support same quantization precision
        static_assert(std::is_same_v<DTypeQ, DTypeKV>);

        bool same_schedule_for_all_heads = plan_info.same_schedule_for_all_heads;
        DISPATCH_BOOL(same_schedule_for_all_heads, SAME_SCHEDULER_FOR_ALL_HEADS, [&] {
          cudaError_t status =
              BatchFP8PrefillWithPagedKVCacheDispatched<HEAD_DIM_QK, MASK_MODE, USE_SLIDING_WINDOW,
                                                        SAME_SCHEDULER_FOR_ALL_HEADS,
                                                        AttentionVariant>(params, enable_pdl,
                                                                          stream);
          TORCH_CHECK(status == cudaSuccess,
                      "BatchPrefillWithPagedKVCacheSM90Run failed with error: ",
                      cudaGetErrorString(status));
          return true;
        });
      });
}
