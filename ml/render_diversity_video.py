"""Frame-by-frame ONNX mask preview, sampled at 8 fps. No tracker/phone emulation."""
import json
import argparse
from pathlib import Path
import cv2
import numpy as np
import onnxruntime as ort

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'scratch/vehicle-diversity'

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--model',type=Path,default=ROOT/'My project/Assets/Resources/CarSegMask.onnx')
    parser.add_argument('--out',type=Path,default=OUT)
    args=parser.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    opts=ort.SessionOptions();opts.intra_op_num_threads=4
    sess=ort.InferenceSession(str(args.model),sess_options=opts,providers=['CPUExecutionProvider'])
    manifest=json.loads((OUT/'sources.json').read_text(encoding='utf8'))
    stats=[]
    for src in manifest:
        if not src['path'].endswith('.mp4'):continue
        cap=cv2.VideoCapture(str(ROOT/src['path']))
        duration=cap.get(cv2.CAP_PROP_FRAME_COUNT)/max(1,cap.get(cv2.CAP_PROP_FPS))
        writer=cv2.VideoWriter(str(args.out/(src['id']+'-mask-raw.mp4')),cv2.VideoWriter_fourcc(*'mp4v'),8,(1280,396))
        for t in np.arange(0,min(duration,12),1/8):
            cap.set(cv2.CAP_PROP_POS_MSEC,float(t)*1000);ok,im=cap.read()
            if not ok:break
            im=cv2.resize(im,(640,360))
            inp=cv2.cvtColor(cv2.resize(im,(384,384)),cv2.COLOR_BGR2RGB).transpose(2,0,1)[None].astype(np.float32)/255
            prob=sess.run(None,{sess.get_inputs()[0].name:inp})[0][0,0]
            selected=cv2.resize(prob,(640,360))>.16
            overlay=im.copy();overlay[selected]=(im[selected]*.4+np.array([35,235,35])*.6).astype(np.uint8)
            bar=np.full((36,1280,3),18,np.uint8)
            cv2.putText(bar,src['id']+f' | source {t:.2f}s | original / ONNX | sampled 8fps, no tracker',(8,24),0,.53,(255,255,255),1,cv2.LINE_AA)
            writer.write(np.vstack([bar,np.hstack([im,overlay])]))
            stats.append({'video':src['id'],'seconds':round(float(t),3),'mask_coverage':round(float(selected.mean()),4),
                          'sky_roi_spill':float(selected[20:80,420:600].mean()) if src['id']=='bmw-video' else None})
        writer.release();cap.release();print(src['id']+' complete',flush=True)
    (args.out/'video-mask-samples.json').write_text(json.dumps(stats,indent=2))

if __name__=='__main__':main()
