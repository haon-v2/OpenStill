"""No downloaded model required: deterministic mock verifies exchange and boundaries."""
import importlib.util
import pathlib
import tempfile
import types
import unittest
import numpy as np
from PIL import Image

spec = importlib.util.spec_from_file_location('float_bridge', pathlib.Path(__file__).parents[1]/'Resources/AI/float_bridge.py')
bridge = importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)

class Model:
    def __init__(self, tool): self.tool = tool
    def get_inputs(self): return [types.SimpleNamespace(name='image')]
    def get_outputs(self): return [types.SimpleNamespace(name='mask')]
    def run(self, _, inputs):
        data = inputs['image']
        if self.tool == 'sky':
            mask = np.zeros((1,1,320,320),np.float32); mask[:,:,:160] = 1; return [mask]
        if self.tool == 'erase': return [data*255]
        return [data]

class FloatBridgeTests(unittest.TestCase):
    def test_round_trip_and_models_preserve_sub_byte_precision(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            original = np.zeros((70,90,4),np.float32)
            original[:,:,:3] = np.array([.123456,.345678,1.25]); original[:,:,3] = .75
            original[10,11,0] = -.12
            input_file, output = folder/'input.osfloat', folder/'out.osfloat'
            bridge.write(input_file,original)
            np.testing.assert_array_equal(bridge.read(input_file),original)
            for tool in ['denoise','detail']:
                bridge.run(types.SimpleNamespace(tool=tool,input=input_file,output=output),Model,lambda _:None)
                np.testing.assert_allclose(bridge.read(output),original,atol=2e-7)
            mask = np.zeros((70,90),np.uint8); mask[30:40,35:45] = 255
            mask_file=folder/'mask.png'; Image.fromarray(mask).save(mask_file)
            bridge.run(types.SimpleNamespace(tool='erase',input=input_file,output=output,mask=mask_file),Model,lambda _:None)
            result=bridge.read(output)
            np.testing.assert_array_equal(result[mask==0],original[mask==0])
            np.testing.assert_array_equal(result[:,:,3],original[:,:,3])
    def test_invalid_payload(self):
        with tempfile.TemporaryDirectory() as folder:
            path=pathlib.Path(folder)/'bad.osfloat'; path.write_bytes(b'OSF1')
            with self.assertRaises(ValueError): bridge.read(path)

if __name__ == '__main__': unittest.main()
