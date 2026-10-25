"""Offline source/ONNX parity and colour-gate ablation. Never exports model weights."""
import hashlib
import json
import sys
import time
from pathlib import Path
import cv2
import numpy as np
import onnxruntime as ort
import torch
import torch.nn.functional as F
from export_sentis_mask import VehiclePaintMaskWrapper

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'scratch/three-car-evaluation'
MODEL=ROOT/'My project/Assets/Resources/CarSegMask.onnx'
DOWNLOADS=Path.home()/'Downloads'
NEW='AR Car Customizer Repo Overview - Google Gemini.mp4'
OLD='AR Video Code Fixes - Google Gemini(1).mp4'
CASES=[('black-front',NEW,15,True),('grey-front',NEW,50,True),
       ('white-front',NEW,80,True),('black-rear',NEW,245,True),
       ('empty-wall',NEW,40,False),('clean-white-front',OLD,43,False),
       ('clean-white-rear',OLD,117,False)]

def panel(im,title):
    bar=np.full((36,640,3),22,np.uint8)
    cv2.putText(bar,title,(8,24),0,.49,(255,255,255),1,cv2.LINE_AA)
    return np.vstack([bar,im])

def overlay(im,m):
    alpha=cv2.resize(m,(640,440))[:,:,None]*.65
    return np.clip(im*(1-alpha)+np.array([30,235,40])*alpha,0,255).astype(np.uint8)

def finish_mask(body,cutout,lum,presence):
    clean=torch.clamp(body-cutout*1.45,0,1)
    p=F.interpolate(F.avg_pool2d(clean,3,1,1),size=(384,384),mode='bilinear',align_corners=False)
    avg=lambda t:F.avg_pool2d(t,9,1,4)
    mi,mp=avg(lum),avg(p)
    a=(avg(lum*p)-mi*mp)/(torch.clamp(avg(lum*lum)-mi*mi,min=0)+.0015)
    guided=torch.clamp(avg(a)*lum+avg(mp-a*mi),0,1)
    return torch.clamp(torch.clamp((guided-.24)/.34,0,1)*1.25,0,1)*presence

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    torch.set_num_threads(4)
    wrapper=VehiclePaintMaskWrapper(str(ROOT/'ml/yolov8n-seg.pt'),str(ROOT/'ml/parts_segmentation.pt')).eval()
    opts=ort.SessionOptions();opts.intra_op_num_threads=4
    session=ort.InferenceSession(str(MODEL),sess_options=opts,providers=['CPUExecutionProvider'])
    captured={}
    def trace(frame,event,arg):
        if event=='return' and frame.f_code is VehiclePaintMaskWrapper.forward.__code__:
            captured.update(frame.f_locals)
    records=[]
    writer=cv2.VideoWriter(str(OUT/'comparison-raw.mp4'),cv2.VideoWriter_fourcc(*'mp4v'),1,(1280,952))
    for name,video,stamp,painted in CASES:
        cap=cv2.VideoCapture(str(DOWNLOADS/video));cap.set(cv2.CAP_PROP_POS_MSEC,stamp*1000)
        ok,frame=cap.read();cap.release()
        if not ok:raise RuntimeError(name)
        image=cv2.resize(frame[390:1130,:],(640,440),interpolation=cv2.INTER_AREA)
        inp=cv2.cvtColor(cv2.resize(image,(384,384),interpolation=cv2.INTER_AREA),cv2.COLOR_BGR2RGB).transpose(2,0,1)[None].astype(np.float32)/255
        t=time.perf_counter();onnx=session.run(None,{session.get_inputs()[0].name:inp})[0]
        elapsed=time.perf_counter()-t
        captured.clear()
        sys.setprofile(trace)
        try:
            with torch.no_grad():baseline=wrapper(torch.from_numpy(inp)).numpy()
        finally:sys.setprofile(None)
        diff=float(np.max(np.abs(onnx-baseline)))
        v=captured
        with torch.no_grad():
            # Diagnostic only: colour-independent semantic masks; no geometry/top/box changes.
            assist=v['sil_eroded']*torch.clamp(v['structure_halo']*1.15,0,.90)
            body=torch.maximum(v['parts_paint'],assist)
            cut=torch.maximum(torch.maximum(v['win_raw'],v['wheel_raw']),torch.maximum(v['grille_raw'],v['lamps_plate_raw']))
            experiment=finish_mask(body,cut,v['luma_384'],v['car_presence']).numpy()
            # Secondary diagnostic: strict whole-car envelope can reduce spill, but lose close-ups.
            strict=experiment*F.interpolate(v['car_silhouette'],size=(384,384),mode='bilinear',align_corners=False).numpy()
        row={'case':name,'source':video,'seconds':stamp,'already_painted':painted,
             'max_source_onnx_difference':diff,'source_parity_pass':diff<.001,
             'onnx_cpu_seconds':round(elapsed,4)}
        for key in ('veh_presence','parts_presence','car_presence','parts_paint','cutout','win_sealed','car_silhouette'):
            row[key+'_max']=float(v[key].max())
            row[key+'_mean']=float(v[key].mean())
        for key,m in [('baseline',onnx),('neutral',experiment),('strict',strict)]:
            row[key+'_coverage']=round(float((m>.16).mean()),4)
            np.save(OUT/f'{name}-{key}.npy',m[0,0])
        row['dark_trim_suppression_mean']=float((v['parts_paint']*v.get('dark_trim_gate', torch.zeros_1)(*v['win_frame_zone'])).mean()) if 'dark_trim_gate' in v else 0.0
        cv2.imwrite(str(OUT/f'{name}-source.png'),image)
        sheet=np.vstack([np.hstack([panel(image,name+(' | ALREADY PAINTED' if painted else ' | clean control')),panel(overlay(image,onnx[0,0]),'Shipped ONNX baseline')]),
                         np.hstack([panel(overlay(image,experiment[0,0]),'Experiment: no brightness body/trim rules'),panel(overlay(image,strict[0,0]),'Experiment + strict vehicle envelope')])])
        cv2.imwrite(str(OUT/f'{name}.jpg'),sheet)
        for _ in range(3):writer.write(sheet)
        records.append(row);print(json.dumps(row),flush=True)
    writer.release()
    report={'model':str(MODEL),'model_sha256':hashlib.sha256(MODEL.read_bytes()).hexdigest(),
            'crop_xyxy':[0,390,1080,1130],'threshold':.16,'cases':records,
            'limitations':['Screen recording crops differ from real Unity camera tensors.',
              'Already-painted views are diagnostic only, not ground truth or training inputs.',
              'Coverage is not accuracy. No phone timing or full-mask accuracy is claimed.',
              'Neutral experiment still retains original anchor location/box/confidence gates.',
              'Ablations are source diagnostics only when ONNX parity passes.']}
    (OUT/'metrics.json').write_text(json.dumps(report,indent=2))

if __name__=='__main__':main()
