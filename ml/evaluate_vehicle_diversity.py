"""Evaluate downloaded, attributed sources through shipped ONNX and production HD.

Acceptance from process_frame is not an accuracy score. Outputs require visual review.
"""
import base64
import hashlib
import json
import time
import argparse
from pathlib import Path
import cv2
import numpy as np
import onnxruntime as ort
import torch
import live_segment_worker as worker

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'scratch/vehicle-diversity'

def fit(im):
    h,w=im.shape[:2];scale=min(480/w,320/h)
    small=cv2.resize(im,(max(1,int(w*scale)),max(1,int(h*scale))))
    panel=np.full((320,480,3),25,np.uint8)
    y=(320-small.shape[0])//2;x=(480-small.shape[1])//2
    panel[y:y+small.shape[0],x:x+small.shape[1]]=small
    return panel

def label(im,text):
    bar=np.full((36,480,3),18,np.uint8)
    cv2.putText(bar,text[:62],(6,24),0,.43,(255,255,255),1,cv2.LINE_AA)
    return np.vstack([bar,fit(im)])

def main():
    global OUT
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,default=OUT)
    guarded=ROOT/'My project/Assets/Resources/CarSegMaskGuarded.onnx'
    parser.add_argument('--model',type=Path,default=guarded if guarded.exists() else ROOT/'My project/Assets/Resources/CarSegMask.onnx')
    args=parser.parse_args();OUT=args.out;OUT.mkdir(parents=True,exist_ok=True)
    torch.set_num_threads(4)
    manifest=json.loads((ROOT/'scratch/vehicle-diversity/sources.json').read_text(encoding='utf8'))
    opts=ort.SessionOptions();opts.intra_op_num_threads=4
    model_path=args.model
    session=ort.InferenceSession(str(model_path),sess_options=opts,providers=['CPUExecutionProvider'])
    model=worker.load_model()
    results=[];rows=[]
    cases=[]
    for src in manifest:
        path=ROOT/src['path']
        if path.suffix in ('.webm','.mp4'):
            cap=cv2.VideoCapture(str(path))
            duration=cap.get(cv2.CAP_PROP_FRAME_COUNT)/max(1,cap.get(cv2.CAP_PROP_FPS))
            for t in (1.,round(duration*.5,2),round(max(1,duration-1),2)):
                cap.set(cv2.CAP_PROP_POS_MSEC,t*1000);ok,im=cap.read()
                if ok:cases.append((src['id']+'-'+str(t),im,src,t))
            cap.release()
        else:
            im=cv2.imread(str(path))
            if im is None:raise RuntimeError(str(path))
            cases.append((src['id'],im,src,None))
    negative=cv2.imread(str(ROOT/'scratch/model-baseline-review/empty-background-source.png'))
    if negative is not None:cases.append(('negative-wall',negative,{'id':'user-wall','license':'User supplied'},62))
    for name,image,src,stamp in cases:
        h,w=image.shape[:2]
        scale=min(1,1600/max(h,w));image=cv2.resize(image,(int(w*scale),int(h*scale)))
        rgb=cv2.cvtColor(cv2.resize(image,(384,384)),cv2.COLOR_BGR2RGB)
        inp=np.ascontiguousarray(rgb.transpose(2,0,1)[None],dtype=np.float32)/255
        tick=time.perf_counter();prob=session.run(None,{session.get_inputs()[0].name:inp})[0][0,0]
        onnx_ms=(time.perf_counter()-tick)*1000
        mask=cv2.resize(prob,(image.shape[1],image.shape[0]))>.16
        overlay=image.copy();overlay[mask]=(image[mask]*.4+np.array([35,235,35])*.6).astype(np.uint8)
        payload=base64.b64encode(cv2.imencode('.jpg',image)[1]).decode()
        tick=time.perf_counter()
        response=worker.process_frame(model,payload,hd_mode=True,frame_id='diversity-'+name,hex_color='#B7B7BE',finish='metallic')
        row={'case':name,'source_id':src['id'],'seconds':stamp,'hd_accepted':bool(response.get('ok')),
             'hd_reason':response.get('reason'),'hd_source':response.get('source'),
             'hd_seconds':round(time.perf_counter()-tick,3),'onnx_cpu_ms':round(onnx_ms,1),
             'onnx_coverage':round(float(mask.mean()),4)}
        panels=[label(image,name+' | original'),label(overlay,'Selected ONNX mask | stretch proxy')]
        if response.get('ok'):
            cache=worker.cache_get_frame('diversity-'+name)
            cv2.imwrite(str(OUT/(name+'-hd-mask.png')),cache['mask_u8'])
            row['hd_coverage']=float(np.mean(cache['mask_u8']>64))
            for finish,color in [('matte','#1C1C1C'),('metallic','#B7B7BE'),('carbon','#111111')]:
                painted=worker.process_frame(model,'',hd_mode=True,repolish_only=True,frame_id='diversity-'+name,finish=finish,hex_color=color)
                if not painted.get('ok'):raise RuntimeError(painted)
                im=cv2.imdecode(np.frombuffer(base64.b64decode(painted['polishedBase64']),np.uint8),cv2.IMREAD_COLOR)
                cv2.imwrite(str(OUT/(name+'-'+finish+'.jpg')),im)
                panels.append(label(im,'HD '+finish+' | inspect boundaries'))
        else:
            for _ in range(3):panels.append(label(image,'HD REJECTED | '+str(response.get('reason'))))
        sheet=cv2.hconcat(panels)
        cv2.imwrite(str(OUT/(name+'-comparison.jpg')),sheet)
        cv2.imwrite(str(OUT/(name+'-source.jpg')),image)
        np.save(OUT/(name+'-onnx.npy'),prob)
        rows.append(cv2.resize(sheet,(1200,178)))
        results.append(row)
        (OUT/'results.json').write_text(json.dumps({'model_sha256':hashlib.sha256(model_path.read_bytes()).hexdigest(),'results':results},indent=2))
        print(json.dumps(row),flush=True)
    cv2.imwrite(str(OUT/'all-comparisons.jpg'),cv2.vconcat(rows))
    writer=cv2.VideoWriter(str(OUT/'review-raw.mp4'),cv2.VideoWriter_fourcc(*'mp4v'),8,(2400,356))
    for row in results:
        im=cv2.imread(str(OUT/(row['case']+'-comparison.jpg')))
        for _ in range(24):writer.write(im)
    writer.release()

if __name__=='__main__':main()
