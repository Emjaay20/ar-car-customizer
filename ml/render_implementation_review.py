"""Offline production-HD preview and rejected-negative evidence; no phone claims."""
import base64
import json
from pathlib import Path
import cv2
import numpy as np
import live_segment_worker as worker
from ultralytics import YOLO

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'scratch/implementation-review'

def label(im,title):
    im=cv2.resize(im,(480,330))
    bar=np.full((34,480,3),20,np.uint8)
    cv2.putText(bar,title,(8,23),0,.5,(255,255,255),1,cv2.LINE_AA)
    return np.vstack([bar,im])

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    cap=cv2.VideoCapture(str(Path.home()/'Downloads/AR Video Code Fixes - Google Gemini(1).mp4'))
    model=YOLO(str(ROOT/'yolov8n-seg.pt'))
    rows=[];summary=[]
    for name,t in [('front',43),('rear',117),('wall',62)]:
        cap.set(cv2.CAP_PROP_POS_MSEC,t*1000);ok,frame=cap.read()
        if not ok:raise RuntimeError(t)
        image=frame[390:1130,:]
        payload=base64.b64encode(cv2.imencode('.jpg',image)[1]).decode()
        first=worker.process_frame(model,payload,hd_mode=True,frame_id='review_'+name,finish='matte',hex_color='#1C1C1C')
        summary.append({'case':name,'ok':first.get('ok'),'reason':first.get('reason'),'source':first.get('source')})
        panels=[label(image,name+' | source')]
        if first.get('ok'):
            cached=worker.cache_get_frame('review_'+name)
            for finish,color in [('matte','#1C1C1C'),('metallic','#B7B7BE'),('carbon','#111111')]:
                result=worker.process_frame(model,'',repolish_only=True,hd_mode=True,frame_id='review_'+name,finish=finish,hex_color=color)
                if not result.get('ok'):raise RuntimeError(result)
                painted=cv2.imdecode(np.frombuffer(base64.b64decode(result['polishedBase64']),np.uint8),cv2.IMREAD_COLOR)
                panels.append(label(painted,finish+' | updated HD compositor'))
        else:
            for _ in range(3):panels.append(label(image,'Rejected: '+first.get('reason','unknown')[:55]))
        row=cv2.hconcat(panels);rows.append(row)
        cv2.imwrite(str(OUT/(name+'-finishes.jpg')),row)
        print(summary[-1],flush=True)
    cv2.imwrite(str(OUT/'finish-review.jpg'),cv2.vconcat(rows))
    (OUT/'preview-results.json').write_text(json.dumps(summary,indent=2))
    cap.release()

if __name__=='__main__':main()
