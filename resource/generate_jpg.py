import numpy as np
import pdb
import os
import cv2
from tqdm import tqdm


result_path = "./lenet_quant_data"


if __name__ == '__main__':
    for i in tqdm(range(200)):
        data_hwc = np.random.random((32,32,1))
        x = np.array(data_hwc, dtype=np.float32)
        new_path_name = os.path.join(result_path,str(i)) + ".jpg"
        cv2.imwrite(new_path_name, x)
            
