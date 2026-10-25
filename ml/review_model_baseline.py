"""Reproducible offline ONNX audit with sparse, human-selected interior regions.

Labels are NOT full reference masks. Unlabelled pixels are ignored in ROI scores.
Screen-recording crops are not a substitute for captured Unity input tensors.
"""
import hashlib
import json
import time
from pathlib import Path
import cv2
import numpy as np
import onnxruntime as ort
from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'scratch/model-baseline-review'
MODEL = ROOT / 'My project/Assets/Resources/CarSegMask.onnx'
VIDEO = Path(r'C:\Users\USER\Downloads\AR Video Code Fixes - Google Gemini(1).mp4')
# Coordinates in the 640x440 review crop: class 1 paint, class 2 protected/background.
REGIONS = {
 'front': [(1,[(150,110),(480,110),(460,190),(180,190)]),
           (2,[(160,5),(465,5),(480,45),(150,45)]),
           (2,[(285,380),(375,380),(375,415),(285,415)])],
 'side-close': [(1,[(230,150),(430,130),(580,150),(580,168),(260,204)]),
                (2,[(200,375),(420,300),(560,300),(560,420),(200,420)])],
 'rear': [(1,[(230,200),(420,200),(420,220),(230,220)]),
          (1,[(200,330),(420,330),(420,365),(200,365)]),
          (2,[(290,120),(450,120),(430,160),(290,155)]),
          (2,[(285,230),(330,230),(330,260),(285,260)]),
          (2,[(180,190),(200,195),(205,220),(185,215)])],
 'empty-background': [(2,[(10,10),(630,10),(630,430),(10,430)])],
}
CASES=[('front',43),('front-close',45),('side',82),('side-close',84),('rear',117),('rear-moving',119),('empty-background',62)]

def tagged(im,text):
    bar=np.full((36,im.shape[1],3),22,np.uint8)
    cv2.putText(bar,text,(8,24),cv2.FONT_HERSHEY_SIMPLEX,.49,(255,255,255),1,cv2.LINE_AA)
    return np.vstack([bar,im])

def overlay(im,m,color=(50,240,30)):
    a=(m.astype(np.float32)/255*.60)[:,:,None]
    return (im*(1-a)+np.array(color)*a).astype(np.uint8)

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    options=ort.SessionOptions()
    options.intra_op_num_threads=4
    session=ort.InferenceSession(str(MODEL),sess_options=options,providers=['CPUExecutionProvider'])
    parts=YOLO(str(ROOT/'ml/parts_segmentation.pt'))
    cap=cv2.VideoCapture(str(VIDEO))
    records=[]
    sheets=[]
    for name,stamp in CASES:
        cap.set(cv2.CAP_PROP_POS_MSEC,stamp*1000)
        ok,raw=cap.read()
        if not ok: raise RuntimeError(f'Missing frame {stamp}')
        image=cv2.resize(raw[390:1130,:],(640,440),interpolation=cv2.INTER_AREA)
        inp=cv2.cvtColor(cv2.resize(image,(384,384),interpolation=cv2.INTER_AREA),cv2.COLOR_BGR2RGB)
        tensor=np.ascontiguousarray(inp.transpose(2,0,1)[None],dtype=np.float32)/255
        tick=time.perf_counter()
        prob=session.run(None,{session.get_inputs()[0].name:tensor})[0][0,0]
        elapsed=time.perf_counter()-tick
        pred=cv2.resize(prob,(640,440),interpolation=cv2.INTER_LINEAR)>.16
        desktop=np.zeros((440,640),np.uint8)
        excluded=np.zeros((440,640),bool)
        result=parts(image,conf=.12,retina_masks=True,verbose=False)[0]
        predictions=[]
        if result.masks is not None:
            for i,c in enumerate(result.boxes.cls):
                part=parts.names[int(c)]
                predictions.append([part,round(float(result.boxes.conf[i]),3)])
                mask=cv2.resize(result.masks.data[i].cpu().numpy(),(640,440))>.4
                if any(s in part for s in ('window','windshield','wheel','headlight','tail-light','license','grille')):
                    excluded |= mask
                else: desktop[mask]=255
        desktop[excluded]=0
        labels=np.zeros((440,640),np.uint8)
        for cls,poly in REGIONS.get(name,[]):
            cv2.fillPoly(labels,[np.array(poly,np.int32)],cls)
        ref=image.copy()
        ref[labels==1]=(.4*ref[labels==1]+.6*np.array([30,220,30])).astype(np.uint8)
        ref[labels==2]=(.4*ref[labels==2]+.6*np.array([220,30,220])).astype(np.uint8)
        row={'case':name,'seconds':stamp,'source_video':VIDEO.name,'onnx_cpu_seconds':round(elapsed,3),
             'onnx_paint_fraction':round(float(pred.mean()),4),'parts_predictions':predictions}
        for runner,binary in [('onnx',pred),('desktop_parts',desktop>127)]:
            row[runner+'_body_roi_recall']=round(float(binary[labels==1].mean()),4) if np.any(labels==1) else None
            row[runner+'_protected_roi_spill']=round(float(binary[labels==2].mean()),4) if np.any(labels==2) else None
        fullprob=cv2.resize(prob,(640,440),interpolation=cv2.INTER_LINEAR)
        row['threshold_sweep']=[{'threshold':t,
            'body_recall':round(float((fullprob[labels==1]>t).mean()),4) if np.any(labels==1) else None,
            'protected_spill':round(float((fullprob[labels==2]>t).mean()),4) if np.any(labels==2) else None}
            for t in (.16,.35,.5,.7)]
        row['labelled_pixels']=int(np.count_nonzero(labels))
        records.append(row)
        sheet=np.vstack([np.hstack([tagged(image,f'{name} | source {stamp}s'),tagged(ref,'Sparse labels: green body / purple exclude')]),
                         np.hstack([tagged(overlay(image,pred.astype(np.uint8)*255),'Current ONNX | threshold .16'),tagged(overlay(image,desktop),'Desktop semantic parts | comparison only')])])
        cv2.imwrite(str(OUT/f'{name}.jpg'),sheet)
        cv2.imwrite(str(OUT/f'{name}-source.png'),image)
        cv2.imwrite(str(OUT/f'{name}-labels.png'),labels)
        cv2.imwrite(str(OUT/f'{name}-onnx.png'),pred.astype(np.uint8)*255)
        np.save(OUT/f'{name}-probabilities.npy',prob)
        sheets.append(cv2.resize(sheet,(640,476)))
        print(json.dumps(row),flush=True)
    # Black frame sanity check is not a real no-car-scene evaluation.
    blank=session.run(None,{session.get_inputs()[0].name:np.zeros((1,3,384,384),np.float32)})[0]
    report={'model_sha256':hashlib.sha256(MODEL.read_bytes()).hexdigest(),'source':str(VIDEO),
            'crop_xyxy':[0,390,1080,1130],'resize':[640,440],'threshold':.16,
            'label_policy':'Sparse interior polygons; unlabelled pixels ignored. No full-mask IoU or boundary score.',
            'runtime':'ONNX Runtime CPU, four threads; not Unity or phone timing',
            'blank_max':float(blank.max()),'cases':records,'regions':REGIONS}
    (OUT/'metrics.json').write_text(json.dumps(report,indent=2))
    cv2.imwrite(str(OUT/'contact-sheet.jpg'),cv2.vconcat(sheets))
    cap.release()

if __name__=='__main__': main()
