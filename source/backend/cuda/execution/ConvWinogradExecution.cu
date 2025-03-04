//
//  ConvWinogradExecution.cpp
//  MNN
//
//  Created by MNN on 2022/05/11.
//  Copyright © 2018, Alibaba Group Holding Limited
//
#include "ConvWinogradExecution.hpp"
#include "math/WingoradGenerater.hpp"
#include "WinogradTrans.cuh"

namespace MNN {
namespace CUDA {

#define UNIT 2
__global__ void WinoWeightReorder(const float* GgGt, 
    half* GgGt_trans,
    const int block,
    const int co_pack,
    const int ci_pack,
    const int unitCi,
    const int unitCo
    ) {
    const int maxCount = block * co_pack * ci_pack;
    for(size_t index = blockIdx.x * blockDim.x + threadIdx.x; index < maxCount; index += gridDim.x * blockDim.x) {
        size_t tmp =  index / ci_pack;
        size_t ci_idx =  index % ci_pack;

        size_t block_idx =  tmp / co_pack;
        size_t co_idx = tmp % co_pack;
        // [4x4, Cop, Cip, unitCi, unitCo] -->> [4x4, Cop*unitCo, Cip*unitCi]
        size_t src_idx = block_idx * (co_pack*ci_pack) + (co_idx/unitCo) * (ci_pack*unitCo) + (ci_idx/unitCi) * (unitCi*unitCo) + (ci_idx%unitCi) * unitCo + (co_idx%unitCo);
        *(GgGt_trans + index) = *(GgGt + src_idx);
    }
}

bool ConvWinogradExecution::isValid(const Convolution2D* conv) {
    //return false;
    if(conv->common()->strideX() != 1 || conv->common()->strideY() != 1) {
        return false;
    }
    if(conv->common()->dilateX() != 1 || conv->common()->dilateY() != 1) {
        return false;
    }
    if(conv->common()->padX() != 1 || conv->common()->padY() != 1) {
        return false;
    }
    return (conv->common()->kernelX() == 3) && (conv->common()->kernelY() == 3);
}

ConvWinogradExecution::Resource::Resource(Backend* backend, const MNN::Op* op) {
    mBackend = backend;
    auto runtime = static_cast<CUDABackend*>(backend)->getCUDARuntime();

    auto conv       = op->main_as_Convolution2D();
    auto common     = conv->common();
    mKernelInfo.kernelX        = common->kernelX();
    mKernelInfo.kernelY        = common->kernelY();
    mKernelInfo.groups         = common->group();
    mKernelInfo.strideX        = common->strideX();
    mKernelInfo.strideY        = common->strideY();
    mKernelInfo.dilateX        = common->dilateX();
    mKernelInfo.dilateY        = common->dilateY();
    mKernelInfo.activationType = common->relu() ? 1 : (common->relu6() ? 2 : 0);

    //weight host->device
    const float* filterDataPtr = nullptr;
    int weightSize = 0;
    std::shared_ptr<ConvolutionCommon::Int8Common> quanCommon;
    ConvolutionCommon::getConvParameters(&quanCommon, conv, &filterDataPtr, &weightSize);
    mKernelInfo.kernelN = common->outputCount();
    mKernelInfo.kernelC = weightSize / mKernelInfo.kernelN / mKernelInfo.kernelX / mKernelInfo.kernelY;

    const int kernel = 3;
    Math::WinogradGenerater generator(UNIT, kernel, 1.0);
    std::shared_ptr<Tensor> srcWeight(Tensor::create<float>({mKernelInfo.kernelN, mKernelInfo.kernelC, mKernelInfo.kernelY, mKernelInfo.kernelX},
        (void *)filterDataPtr, Tensor::CAFFE));

    auto dstWeight = generator.allocTransformWeight(srcWeight.get(), PACK_NUMBER, PACK_NUMBER);
    generator.transformWeight(dstWeight.get(), srcWeight.get());
    auto dstWeightSize = dstWeight->elementSize();

    // Reorder weight
    {
        auto tempCacheBuffer = static_cast<CUDABackend*>(backend)->getStaticBufferPool()->alloc(dstWeightSize*sizeof(float));
        float* cacheWeight = (float*)((uint8_t*)tempCacheBuffer.first + tempCacheBuffer.second);
        runtime->memcpy(cacheWeight, dstWeight->host<uint8_t>(), dstWeightSize * sizeof(float), MNNMemcpyHostToDevice);
        weightTensor.reset(Tensor::createDevice<int16_t>({dstWeightSize}));
        backend->onAcquireBuffer(weightTensor.get(), Backend::STATIC);
        mFilter = (void *)weightTensor.get()->buffer().device;
        auto& prop = runtime->prop();
        int cores = prop.multiProcessorCount;
        int threadNumbers = prop.maxThreadsPerBlock;

        int coPack = UP_DIV(mKernelInfo.kernelN, PACK_NUMBER) * PACK_NUMBER;
        int ciPack = UP_DIV(mKernelInfo.kernelC, PACK_NUMBER) * PACK_NUMBER;

        WinoWeightReorder<<<cores, threadNumbers>>>((float*)cacheWeight, (half*)mFilter,
                (UNIT+kernel-1) * (UNIT+kernel-1), coPack, ciPack, PACK_NUMBER, PACK_NUMBER);

        static_cast<CUDABackend*>(backend)->getStaticBufferPool()->free(tempCacheBuffer);
    }
    
    // Copy Bias
    int biasSize = conv->bias()->size();
    int alignSize = UP_DIV(biasSize, PACK_NUMBER) * PACK_NUMBER;
    biasTensor.reset(Tensor::createDevice<uint32_t>({alignSize}));
    backend->onAcquireBuffer(biasTensor.get(), Backend::STATIC);

    mBias = (void *)biasTensor.get()->buffer().device;
    cuda_check(cudaMemset(mBias, 0, alignSize*sizeof(float)));
    cuda_check(cudaMemcpy(mBias, conv->bias()->data(), conv->bias()->size()*sizeof(float), cudaMemcpyHostToDevice));

}

ConvWinogradExecution::Resource::~Resource() {
    // Do nothing
}

ConvWinogradExecution::ConvWinogradExecution(Backend* backend, const MNN::Op* op, std::shared_ptr<Resource> res)  : Execution(backend), mOp(op) {
    mResource = res;
    auto staticPool = static_cast<CUDABackend*>(backend)->getStaticBufferPool();
    mGpuMatMulParam = staticPool->alloc(sizeof(MatMulParam));
}
ConvWinogradExecution::~ConvWinogradExecution() {
    auto staticPool = static_cast<CUDABackend*>(backend())->getStaticBufferPool();
    staticPool->free(mGpuMatMulParam);
}

bool ConvWinogradExecution::onClone(Backend* backend, const Op* op, Execution** dst) {
    if (!mValid) {
        return false;
    }
    if(nullptr == dst) {
        return true;
    }
    auto dstExe = new ConvWinogradExecution(backend, op, mResource);
    *dst = dstExe;
    return true;
}

ErrorCode ConvWinogradExecution::onResize(const std::vector<Tensor*>  &inputs, const std::vector<Tensor*> &outputs) {

    auto runtime = static_cast<CUDABackend*>(backend())->getCUDARuntime();

    auto input = inputs[0];
    auto output = outputs[0];
    auto convCommon = mOp->main_as_Convolution2D()->common();
    auto pads = ConvolutionCommon::convolutionPadFull(input, output, mOp->main_as_Convolution2D()->common());
    mPadX = std::get<0>(pads);
    mPadY = std::get<1>(pads);
    int ic = input->channel();
    int icDiv = UP_DIV(ic, PACK_NUMBER);
    auto bytes = static_cast<CUDABackend*>(backend())->getBytes(input);

    auto wUnit = UP_DIV(output->width(), UNIT);
    auto hUnit = UP_DIV(output->height(), UNIT);

    int e = wUnit * hUnit * output->batch();
    int l = ic;
    int h = output->channel();
    mMatMulParam.elh[0] = e;
    mMatMulParam.elh[1] = l;
    mMatMulParam.elh[2] = h;

    int ePack = PACK_NUMBER;
    int hPack = PACK_NUMBER;
    mMatMulParam.elhPack[0] = UP_DIV(e, ePack);
    mMatMulParam.elhPack[1] = UP_DIV(l, PACK_NUMBER);
    mMatMulParam.elhPack[2] = UP_DIV(h, hPack);
    // mMatMulParam.cStride[0] = mIm2ColParamter.ow * mIm2ColParamter.oh * h;
    // mMatMulParam.cStride[1] = 1;
    // mMatMulParam.cStride[2] = mIm2ColParamter.ow * mIm2ColParamter.oh;
    mMatMulParam.minValue = -FLT_MAX;
    mMatMulParam.maxValue = FLT_MAX;
    if (convCommon->relu()) {
        mMatMulParam.minValue = 0.0f;
    }
    if (convCommon->relu6()) {
        mMatMulParam.minValue = 0.0f;
        mMatMulParam.maxValue = 6.0f;
    }
    //MNN_PRINT("!!conv size:3-1, %d-%d-%d, %d-%d-%d\n", input->height(), input->width(), input->channel(), output->height(), output->width(), output->channel());

    runtime->memcpy((uint8_t*)mGpuMatMulParam.first + mGpuMatMulParam.second, &mMatMulParam, sizeof(MatMulParam), MNNMemcpyHostToDevice);

    int block = UNIT + convCommon->kernelY() - 1;
    mBlock2 = block * block;
    auto pool = static_cast<CUDABackend*>(backend())->getBufferPool();
    auto bufferData = pool->alloc((size_t)sizeof(__half) * mBlock2 * mMatMulParam.elhPack[0] * mMatMulParam.elhPack[1] * (size_t)ePack * (size_t)PACK_NUMBER);
    mBtdB_Buffer = (__half*)((uint8_t*)bufferData.first + bufferData.second);
    
    auto bufferMatmul = pool->alloc(bytes * mBlock2 * mMatMulParam.elh[0] * mMatMulParam.elhPack[2] * (size_t)hPack);
    mMatmul_Buffer = (void*)((uint8_t*)bufferMatmul.first + bufferMatmul.second);
    
    pool->free(bufferData);
    pool->free(bufferMatmul);


    mGemmInfo.elh[0] = e;
    mGemmInfo.elh[1] = l;
    mGemmInfo.elh[2] = h;
    mGemmInfo.elhPad[0] = UP_DIV(e, 8) * 8;
    mGemmInfo.elhPad[1] = UP_DIV(l, 8) * 8;
    mGemmInfo.elhPad[2] = UP_DIV(h, 8) * 8;

    ElementComputeEpilogue alpha = ElementComputeEpilogue(1);
    ElementComputeEpilogue beta = ElementComputeEpilogue(0);

    // Split K dimension into 1 partitions
    cutlass::gemm::GemmCoord problem_size(mGemmInfo.elh[0], mGemmInfo.elhPad[2], mGemmInfo.elhPad[1]);// m n k

    //MNN_PRINT("Winograd BatchGemm batch:%d, MNK:%d-%d-%d\n", mBlock2, mGemmInfo.elh[0], mGemmInfo.elhPad[2], mGemmInfo.elhPad[1]);
    if(bytes == 2) {
        typename GemmBatched_F16_Linear_Sm75::Arguments arguments{problem_size,  // <- problem size of matrix multiplication
                                            {(ElementInputA *)mBtdB_Buffer, mGemmInfo.elhPad[1]},  // Ptr + ldm
                                            (int64_t)(mGemmInfo.elh[0] * mGemmInfo.elhPad[1]), // batch_stride_A
                                            {(ElementInputB *)mResource->mFilter, mGemmInfo.elhPad[1]},  //  Ptr + ldm
                                            (int64_t)(mGemmInfo.elhPad[1] * mGemmInfo.elhPad[2]), // batch_stride_B
                                            {(ElementOutput_F16 *)mResource->mBias, 0},  //  Ptr + ldm  if ldm = 0, vector,
                                            (int64_t)(0), // batch_stride_bias
                                            {(ElementOutput_F16 *)mMatmul_Buffer, mGemmInfo.elhPad[2]},  //  Ptr + ldm
                                            (int64_t)(mGemmInfo.elh[0] * mGemmInfo.elhPad[2]),  // batch_stride_C
                                            {alpha, beta},          // <- tuple of alpha and beta
                                            mBlock2};                // batch_count

        size_t workspace_size = GemmBatched_F16_Linear_Sm75::get_workspace_size(arguments);

        auto bufferWs = pool->alloc(workspace_size * sizeof(uint8_t));
        mWorkspace = (uint8_t*)bufferWs.first + bufferWs.second;
        runtime->memset(mWorkspace, 0, workspace_size * sizeof(uint8_t));
        pool->free(bufferWs);

        // Check the problem size is supported or not 
        cutlass::Status status = mGemmBatchedF16LnSm75.can_implement(arguments);
        cutlass_check(status);

        // Initialize CUTLASS kernel with arguments and workspace pointer
        status = mGemmBatchedF16LnSm75.initialize(arguments, (uint8_t *)mWorkspace);
        cutlass_check(status);
    } else {

        typename GemmBatched_F32_Linear_Sm75::Arguments arguments{problem_size,  // <- problem size of matrix multiplication
                                            {(ElementInputA *)mBtdB_Buffer, mGemmInfo.elhPad[1]},  // Ptr + ldm
                                            (int64_t)(mGemmInfo.elh[0] * mGemmInfo.elhPad[1]), // batch_stride_A
                                            {(ElementInputB *)mResource->mFilter, mGemmInfo.elhPad[1]},  //  Ptr + ldm
                                            (int64_t)(mGemmInfo.elhPad[1] * mGemmInfo.elhPad[2]), // batch_stride_B
                                            {(ElementOutput_F32 *)mResource->mBias, 0},  //  Ptr + ldm  if ldm = 0, vector,
                                            (int64_t)(0), // batch_stride_bias
                                            {(ElementOutput_F32 *)mMatmul_Buffer, mGemmInfo.elhPad[2]},  //  Ptr + ldm
                                            (int64_t)(mGemmInfo.elh[0] * mGemmInfo.elhPad[2]),  // batch_stride_C
                                            {alpha, beta},          // <- tuple of alpha and beta
                                            mBlock2};                // batch_count

        size_t workspace_size = GemmBatched_F32_Linear_Sm75::get_workspace_size(arguments);

        auto bufferWs = pool->alloc(workspace_size * sizeof(uint8_t));
        mWorkspace = (uint8_t*)bufferWs.first + bufferWs.second;
        runtime->memset(mWorkspace, 0, workspace_size * sizeof(uint8_t));
        pool->free(bufferWs);

        // Check the problem size is supported or not 
        cutlass::Status status = mGemmBatchedF32LnSm75.can_implement(arguments);
        cutlass_check(status);

        // Initialize CUTLASS kernel with arguments and workspace pointer
        status = mGemmBatchedF32LnSm75.initialize(arguments, (uint8_t *)mWorkspace);
        cutlass_check(status);
    }

    return NO_ERROR;
}

ErrorCode ConvWinogradExecution::onExecute(const std::vector<Tensor*> &inputs, const std::vector<Tensor*> &outputs) {
    auto runtime = static_cast<CUDABackend*>(backend())->getCUDARuntime();
    auto input = inputs[0];
    auto output = outputs[0];
    auto& prop = runtime->prop();
    int cores = prop.multiProcessorCount;
    int threadNumbers = prop.maxThreadsPerBlock / 2;
    auto gpuMatMul = (const MatMulParam*)((uint8_t*)mGpuMatMulParam.first + mGpuMatMulParam.second);

    int co_pack = UP_DIV(mResource->mKernelInfo.kernelN, PACK_NUMBER) * PACK_NUMBER;
    int ci_pack = UP_DIV(mResource->mKernelInfo.kernelC, PACK_NUMBER) * PACK_NUMBER;

    auto bytes = static_cast<CUDABackend*>(backend())->getBytes(input);
    const void *input_addr = (const void*)input->deviceId();
    const void *mGgGt_Buffer = mResource->mFilter;
    const void *bias_addr = mResource->mBias;
    void *output_addr = (void*)output->deviceId();

    const int kernel = 3;
    const int wUnit = UP_DIV(input->width(), UNIT);
    const int hUnit = UP_DIV(input->height(), UNIT);
    DivModFast lD(ci_pack);
    DivModFast hD(co_pack);
    DivModFast whD(wUnit * hUnit);
    DivModFast wD(wUnit);

    if(bytes == 4) {
        WinoInputTrans<<<cores, threadNumbers>>>((const float*)input_addr, (half*)mBtdB_Buffer, UNIT,
                (UNIT+kernel-1)*(UNIT+kernel-1), input->channel(), ci_pack, 
                mMatMulParam.elh[0] * ci_pack, lD, whD, wD,
                mPadX, mPadY, input->width(), input->height());
        checkKernelErrors;
    } else {
        WinoInputTrans<<<cores, threadNumbers>>>((const half*)input_addr, (half*)mBtdB_Buffer, UNIT,
                (UNIT+kernel-1)*(UNIT+kernel-1), input->channel(), ci_pack,
                mMatMulParam.elh[0] * ci_pack, lD, whD, wD,
                mPadX, mPadY, input->width(), input->height());
        checkKernelErrors;
    }

    int maxThreadInWarp = UP_DIV(mBlock2 * mMatMulParam.elhPack[0] * mMatMulParam.elhPack[2], cores);
    int threads_num = std::min(prop.maxThreadsPerBlock/2, maxThreadInWarp * prop.warpSize);
    int basicMemory = 16 * 16 * sizeof(float) * prop.maxThreadsPerBlock / prop.warpSize;

    int iBlock = 0;
    if (4 == bytes) {
        cutlass::Status status = mGemmBatchedF32LnSm75();
        cutlass_check(status);
    } else {
        cutlass::Status status = mGemmBatchedF16LnSm75();
        cutlass_check(status);
    }

    if (4 == bytes) {
        WinoTrans2Output<<<cores, threadNumbers>>>((const float*)mMatmul_Buffer, (const float*)bias_addr, (float*)output_addr,
                gpuMatMul, UNIT, mBlock2, output->channel(), co_pack, 
                mMatMulParam.elh[0] * co_pack, hD, whD, wD,
                output->width(), output->height());
        checkKernelErrors;
    } else {
        WinoTrans2Output<<<cores, threadNumbers>>>((const half*)mMatmul_Buffer, (const float*)bias_addr, (half*)output_addr,
                gpuMatMul, UNIT, mBlock2, output->channel(), co_pack,
                mMatMulParam.elh[0] * co_pack, hD, whD, wD,
                output->width(), output->height());
        checkKernelErrors;
    }

    return NO_ERROR;
}


} // namespace CUDA
} // namespace MNN