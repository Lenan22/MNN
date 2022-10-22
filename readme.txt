mkdir build

cd build

vim option(MNN_BUILD_QUANTOOLS "Build Quantized Tools or not" ON)

./schema/generate.sh

mkdir build && cd build && cmake .. && make -j8

./quantized.out ../mnn_models/lenet_re_ge.mnn ../mnn_models/lenet_re_ge_quant.mnn ../mnn_models/lenet_re_ge.json



./quantized.out face_det_300.mnn face_det_300_quant.mnn face_det.json 


json中有4种格式可以选择"RGB", "BGR", "RGBA", "GRAY"


cmake .. -DMNN_OPENCL=true -DMNN_SEP_BUILD=false -DMNN_BUILD_CONVERTER=true -DMNN_BUILD_TORCH=true -DMNN_BUILD_DEMO=true -DMNN_BUILD_BENCHMARK=true -DMNN_BUILD_TOOLS=true -DCMAKE_INSTALL_PREFIX=./install

make -j8

make install


./MNNConvert -f ONNX --modelFile pinet_v2.onnx --MNNModel pinet_v2.mnn --bizCode biz
