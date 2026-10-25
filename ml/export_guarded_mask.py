"""Export an instance/exterior-guarded model to scratch, never replace live weights."""
import argparse
import hashlib
import json
from pathlib import Path
import cv2
import numpy as np
import onnx
import onnxruntime as ort
import torch
from export_sentis_mask import VehiclePaintMaskWrapper

ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,default=ROOT/'scratch/guarded-live/CarSegMaskGuarded.onnx')
    args=parser.parse_args();args.output.parent.mkdir(parents=True,exist_ok=True)
    torch.set_num_threads(4)
    model=VehiclePaintMaskWrapper(str(ROOT/'ml/yolov8n-seg.pt'),str(ROOT/'ml/parts_segmentation.pt'),guarded=True).eval()
    torch.onnx.export(model,torch.zeros(1,3,384,384),str(args.output),input_names=['input'],
        output_names=['output'],opset_version=12,dynamo=False,do_constant_folding=True)
    proto=onnx.load(str(args.output),load_external_data=True)
    onnx.save_model(proto,str(args.output),save_as_external_data=False)
    onnx.checker.check_model(proto)
    opts=ort.SessionOptions();opts.intra_op_num_threads=4
    session=ort.InferenceSession(str(args.output),sess_options=opts,providers=['CPUExecutionProvider'])
    rows=[]
    for path in (ROOT/'scratch/vehicle-diversity').glob('*-source.jpg'):
        im=cv2.imread(str(path))
        tensor=cv2.cvtColor(cv2.resize(im,(384,384)),cv2.COLOR_BGR2RGB).transpose(2,0,1)[None].astype(np.float32)/255
        with torch.no_grad():ref=model(torch.from_numpy(tensor)).numpy()
        got=session.run(None,{'input':tensor})[0]
        delta=float(np.max(np.abs(ref-got)))
        if delta>.001:raise RuntimeError(f'Export parity failed {path}: {delta}')
        name=path.stem.replace('-source','')
        np.save(args.output.parent/(name+'.npy'),got[0,0])
        selected=cv2.resize(got[0,0],(im.shape[1],im.shape[0]))>.16
        overlay=im.copy();overlay[selected]=(im[selected]*.4+np.array([35,235,35])*.6).astype(np.uint8)
        cv2.imwrite(str(args.output.parent/(name+'.jpg')),overlay)
        rows.append({'case':name,'coverage':float(selected.mean()),'parity_max_difference':delta})
        print(rows[-1],flush=True)
    blank=session.run(None,{'input':np.zeros((1,3,384,384),np.float32)})[0]
    if blank.max()!=0:raise RuntimeError('Blank frame leakage')
    (args.output.parent/'metrics.json').write_text(json.dumps({'cases':rows,'sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),
        'operators':sorted({n.op_type for n in proto.graph.node}),'note':'Postprocessing refinement; no pretrained weights were fine-tuned.'},indent=2))

if __name__=='__main__':main()
