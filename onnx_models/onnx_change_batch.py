import onnx
import onnxruntime
import numpy as np
import onnx.helper as helper
import pdb

onnx_path = "lenet.onnx"

result = "lenet_re_ge.onnx"


batch_size = 1

def change_input_dim(model,):
    inputs = model.graph.input

    # for input in inputs:
    #     # input.type.tensor_type.shape.dim[0].dim_param = "batch"
    #     # input.type.tensor_type.shape.dim[2].dim_param = "height"
    #     # input.type.tensor_type.shape.dim[3].dim_param = "width"

    inputs[0].type.tensor_type.shape.dim[0].dim_param = ""
    inputs[0].type.tensor_type.shape.dim[0].dim_value = 1
    inputs[0].type.tensor_type.shape.dim[1].dim_param = ""
    inputs[0].type.tensor_type.shape.dim[1].dim_value = 3
    inputs[0].type.tensor_type.shape.dim[2].dim_param = ""
    inputs[0].type.tensor_type.shape.dim[2].dim_value = 448
    inputs[0].type.tensor_type.shape.dim[3].dim_param = ""
    inputs[0].type.tensor_type.shape.dim[3].dim_value = 640

    # import pdb
    # pdb.set_trace()

    # outputs = model.graph.output

    # for output in outputs:
    #     output.type.tensor_type.shape.dim[0].dim_param = ""
    #     dim1 = output.type.tensor_type.shape.dim[0]
    #     dim1.dim_value = int(batch_size)

    print("----------")
#        if isinstance(batch_size, str):
#           dim1.dim_param = batch_size
#        elif (isinstance(batch_size, str) and batch_size.isdigit()) or isinstance(batch_size, int):
#           dim1.dim_value = int(batch_size)
#        else:
#           dim1.dim_value = 1

def change_output_dim(model,):
    
    # import pdb
    # pdb.set_trace()

    # del model.graph.output[-1]
    
#    model.graph.output[0].name = "yolo1_out"
    model.graph.output[0].type.tensor_type.shape.dim[0].dim_value = 1
    model.graph.output[0].type.tensor_type.shape.dim[1].dim_value = 400
#    model.graph.output[0].type.tensor_type.shape.dim[2].dim_value = 19
#    model.graph.output[0].type.tensor_type.shape.dim[3].dim_value = 19
#
#    ## 以这种方式来设置onnx的输出
#    model.graph.output.append(model.graph.output[0])
#    model.graph.output.append(model.graph.output[0])
#
#    model.graph.output[1].name = "yolo2_out"
#    model.graph.output[1].type.tensor_type.shape.dim[0].dim_value = 1
#    model.graph.output[1].type.tensor_type.shape.dim[1].dim_value = 36
#    model.graph.output[1].type.tensor_type.shape.dim[2].dim_value = 38
#    model.graph.output[1].type.tensor_type.shape.dim[3].dim_value = 38
#
#    model.graph.output[2].name = "yolo3_out"
#    model.graph.output[2].type.tensor_type.shape.dim[0].dim_value = 1
#    model.graph.output[2].type.tensor_type.shape.dim[1].dim_value = 36
#    model.graph.output[2].type.tensor_type.shape.dim[2].dim_value = 76
#    model.graph.output[2].type.tensor_type.shape.dim[3].dim_value = 76

    # outputs = model.graph.output
    
    # pdb.set_trace()
    # # for output in outputs:
    # #     dim1 = output.type.tensor_type.shape.dim[0]
    # #     dim1.dim_value = int(batch_size)
    # outputs[0].name = "yolo2_out"
    # # outputs[0].type.tensor_type.shape.dim[0].dim_param = ""
    # outputs[0].type.tensor_type.shape.dim[0].dim_value = 1
    # # outputs[0].type.tensor_type.shape.dim[1].dim_param = ""
    # outputs[0].type.tensor_type.shape.dim[1].dim_value = 36
    # # outputs[0].type.tensor_type.shape.dim[2].dim_param = ""
    # outputs[0].type.tensor_type.shape.dim[2].dim_value = 19
    # # outputs[0].type.tensor_type.shape.dim[3].dim_param = ""
    # outputs[0].type.tensor_type.shape.dim[3].dim_value = 19


    # outputs[1] = outputs[0]

    # outputs[1].name = "yolo2"
    # # outputs[1].type.tensor_type.shape.dim[0].dim_param = ""
    # outputs[1].type.tensor_type.shape.dim[0].dim_value = 1
    # # outputs[1].type.tensor_type.shape.dim[1].dim_param = ""
    # outputs[1].type.tensor_type.shape.dim[1].dim_value = 36
    # # outputs[1].type.tensor_type.shape.dim[2].dim_param = ""
    # outputs[1].type.tensor_type.shape.dim[2].dim_value = 38
    # # outputs[1].type.tensor_type.shape.dim[3].dim_param = ""
    # outputs[1].type.tensor_type.shape.dim[3].dim_value = 38


    # outputs[2].name = "yolo3"
    # # outputs[2].type.tensor_type.shape.dim[0].dim_param = ""
    # outputs[2].type.tensor_type.shape.dim[0].dim_value = 1
    # # outputs[2].type.tensor_type.shape.dim[1].dim_param = ""
    # outputs[2].type.tensor_type.shape.dim[1].dim_value = 36
    # # outputs[2].type.tensor_type.shape.dim[2].dim_param = ""
    # outputs[2].type.tensor_type.shape.dim[2].dim_value = 76
    # # outputs[2].type.tensor_type.shape.dim[3].dim_param = ""
    # outputs[2].type.tensor_type.shape.dim[3].dim_value = 76

    # model.graph.output = outputs

def change_model(model,):
    # import pdb
    # pdb.set_trace()
    graph = model.graph
    for node in graph.node:
        # print(node.name)
        if 'Slice_5' in node.name:
            import pdb
            pdb.set_trace()
            print(node)

    print("----------------------------")



def apply(transform, infile, outfile):
    model = onnx.load(infile)
    transform(model,)
    onnx.save(model,outfile)


#bin_file = 'input/input_9.bin'

if __name__ == '__main__':
    # apply(change_input_dim, onnx_path, result)
    apply(change_output_dim, onnx_path, result)
    
    #original_model = onnx.load(onnx_path)   
    #nodeNameList = getNodeNameList(original_model)


    # 获取输入输出
    #session = onnxruntime.InferenceSession(onnx_path)
    #input_name = session.get_inputs()[0].name
    #output_name = session.get_outputs()[0].name
    #print("input_name:",input_name)
    #print("output_name:",output_name)
    #pdb.set_trace()

    #ort_inputs = {input_name:input_data}
    #ort_outs = session.run([output_name], ort_inputs)[0]
    #print(ort_outs)
    #print(np.shape(ort_outs))
