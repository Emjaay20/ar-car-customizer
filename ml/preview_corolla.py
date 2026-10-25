"""Offline review only: semantic paint masks, no app changes or training."""
import json
import time
from pathlib import Path
import cv2
import numpy as np
from ultralytics import YOLO, SAM

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'scratch/corolla-review'
OUT.mkdir(parents=True, exist_ok=True)
SOURCE = Path(r'C:\Users\USER\Downloads\AR Video Code Fixes - Google Gemini(1).mp4')

def label(image, title):
    bar = np.full((40, image.shape[1], 3), 24, np.uint8)
    cv2.putText(bar, title, (10, 26), cv2.FONT_HERSHEY_SIMPLEX, .53, (255,255,255), 1, cv2.LINE_AA)
    return np.vstack([bar, image])

def paint(image, mask, rgb, matte=False):
    f = image.astype(np.float32)/255
    lum = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
    broad = cv2.GaussianBlur(lum, (0,0), 7)
    detail = np.clip((lum+.035)/(broad+.035), .55, 1.5)
    shade = np.clip(.45+.55*lum, .35, 1.) * detail
    color = np.array(rgb[::-1], np.float32)/255
    reflection = np.maximum(lum-broad-.06, 0)**1.2 * (.12 if matte else .9)
    result = np.clip(color[None,None,:]*shade[:,:,None]+reflection[:,:,None],0,1)
    a = mask[:,:,None].astype(np.float32)/255
    return ((f*(1-a)+result*a)*255).astype(np.uint8)

def main():
    vehicle = YOLO(str(ROOT/'yolov8n-seg.pt'))
    parts = YOLO(str(ROOT/'ml/parts_segmentation.pt'))
    sam = SAM(str(ROOT/'sam2_t.pt'))
    cap = cv2.VideoCapture(str(SOURCE))
    stats=[]
    writer=None
    for scene,start in [('front',43),('side',82),('rear',117)]:
        prev=None
        mask=None
        for i in range(24):
            stamp=start+i/8
            cap.set(cv2.CAP_PROP_POS_MSEC, stamp*1000)
            ok, raw=cap.read()
            if not ok: break
            # Screen recording viewport, removing status pill and bottom controls.
            image=cv2.resize(raw[390:1130, :], (640,440))
            gray=cv2.cvtColor(image,cv2.COLOR_BGR2GRAY)
            if i%8==0:
                tick=time.perf_counter()
                result=vehicle(image,classes=[2],conf=.12,retina_masks=True,verbose=False)[0]
                mask=np.zeros(gray.shape,np.uint8)
                baseline=mask.copy()
                if result.masks is not None:
                    areas=[float((b[2]-b[0])*(b[3]-b[1])) for b in result.boxes.xyxy]
                    idx=int(np.argmax(areas))
                    baseline=(result.masks.data[idx].cpu().numpy()*255).astype(np.uint8)
                    baseline=cv2.resize(baseline,(640,440))
                    box=result.boxes.xyxy[idx].tolist()
                    sr=sam(image,bboxes=[box],verbose=False)[0]
                    if sr.masks is not None:
                        mask=cv2.resize((sr.masks.data[0].cpu().numpy()*255).astype(np.uint8),(640,440))
                    else: mask=baseline.copy()
                    # Keep SAM inside a narrow semantic vehicle envelope.
                    envelope=cv2.dilate(baseline,np.ones((9,9),np.uint8))
                    mask=cv2.bitwise_and(mask,envelope)
                    pr=parts(image,conf=.12,retina_masks=True,verbose=False)[0]
                    if pr.masks is not None:
                        for n,c in enumerate(pr.boxes.cls):
                            name=parts.names[int(c)]
                            if any(s in name for s in ('window','windshield','wheel','headlight','tail-light','license','grille')):
                                exclusion=cv2.resize(pr.masks.data[n].cpu().numpy(),(640,440))>.4
                                mask[exclusion]=0
                if not np.any(mask):
                    pr=parts(image,conf=.12,retina_masks=True,verbose=False)[0]
                    exclusion=np.zeros(gray.shape,bool)
                    if pr.masks is not None:
                        for n,c in enumerate(pr.boxes.cls):
                            name=parts.names[int(c)]
                            region=cv2.resize(pr.masks.data[n].cpu().numpy(),(640,440))>.4
                            if any(s in name for s in ('window','windshield','wheel','headlight','tail-light','license','grille')):
                                exclusion |= region
                            else:
                                mask[region]=255
                        mask[exclusion]=0
                    baseline=mask.copy()
                mask=cv2.GaussianBlur(mask,(3,3),.6)
                stats.append(dict(scene=scene,source_seconds=stamp,offline_seconds=round(time.perf_counter()-tick,3),coverage=float(np.mean(mask>127))))
                print(stats[-1],flush=True)
                cv2.imwrite(str(OUT/f'{scene}-{i:02d}-mask.png'),mask)
                cv2.imwrite(str(OUT/f'{scene}-{i:02d}-source.png'),image)
            elif prev is not None:
                # Backward optical flow resamples the prior mask into current coordinates.
                flow=cv2.calcOpticalFlowFarneback(gray,prev,None,.5,3,21,3,5,1.2,0)
                yy,xx=np.mgrid[:440,:640].astype(np.float32)
                mask=cv2.remap(mask,xx+flow[:,:,0],yy+flow[:,:,1],cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
            prev=gray
            overlay=image.copy()
            a=mask[:,:,None]/255*.6
            overlay=(image*(1-a)+np.array([70,240,40])*a).astype(np.uint8)
            black=paint(image,mask,(25,25,28),True)
            red=paint(image,mask,(175,15,35))
            board=np.vstack([np.hstack([label(image,f'Original | {stamp:.2f}s'),label(overlay,'Candidate body mask')]),np.hstack([label(black,'Matte black | offline preview'),label(red,'Gloss red | offline preview')])])
            if writer is None: writer=cv2.VideoWriter(str(OUT/'comparison-raw.mp4'),cv2.VideoWriter_fourcc(*'mp4v'),8,(1280,960))
            writer.write(board)
            if i==0:
                cv2.imwrite(str(OUT/f'{scene}-comparison.jpg'),board)
                cv2.imwrite(str(OUT/f'{scene}-baseline.png'),baseline)
        print('Completed '+scene,flush=True)
    if writer: writer.release()
    cap.release()
    (OUT/'metrics.json').write_text(json.dumps(stats,indent=2))

if __name__=='__main__': main()
