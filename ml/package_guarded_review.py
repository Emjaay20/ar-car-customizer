"""Package actual regression outputs, without claiming device validation."""
import json
from pathlib import Path
import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'scratch/guarded-live'

def main():
    for name in ['bmw-video','convertible-video']:
        a=cv2.VideoCapture(str(ROOT/'scratch/vehicle-diversity'/(name+'-mask-raw.mp4')))
        b=cv2.VideoCapture(str(OUT/(name+'-mask-raw.mp4')))
        writer=cv2.VideoWriter(str(OUT/(name+'-comparison-raw.mp4')),cv2.VideoWriter_fourcc(*'mp4v'),8,(1920,396))
        first=True
        while True:
            ok,x=a.read();ok2,y=b.read()
            if not ok or not ok2:break
            bar=np.full((36,1920,3),18,np.uint8)
            cv2.putText(bar,name+' | ORIGINAL                                      PREVIOUS MASK                                      GUARDED MASK | sampled 8fps',(8,24),0,.60,(255,255,255),1,cv2.LINE_AA)
            board=np.vstack([bar,np.hstack([x[36:,:640],x[36:,640:],y[36:,640:]])])
            writer.write(board)
            if first:cv2.imwrite(str(OUT/(name+'-before-after.jpg')),board);first=False
        a.release();b.release();writer.release()
    parity=[]
    for f in (OUT/'parity').glob('*.onnx.f32'):
        u=Path(str(f).replace('.onnx.f32','.unity.f32'))
        if not u.exists():raise RuntimeError('Unity runtime output missing: '+str(u))
        a=np.fromfile(f,np.float32);b=np.fromfile(u,np.float32)
        row={'case':f.name,'max_error':float(np.max(np.abs(a-b))),
             'mask_disagreement':float(np.mean((a>.16)!=(b>.16)))}
        if row['max_error']>.001:raise RuntimeError(row)
        parity.append(row)
    (OUT/'parity/results.json').write_text(json.dumps(parity,indent=2))
    samples=json.loads((OUT/'video-mask-samples.json').read_text())
    summary={}
    for name in ['bmw-video','convertible-video']:
        cases=[x for x in samples if x['video']==name]
        summary[name]={'sampled_frames':len(cases),'nonempty':sum(x['mask_coverage']>.001 for x in cases),
                       'max_checked_sky_spill':max((x['sky_roi_spill'] or 0) for x in cases)}
    summary['unity_parity']=parity
    summary['student_candidate']=json.loads((ROOT/'scratch/learning-candidate/evaluation.json').read_text())
    (OUT/'summary.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps({k:v for k,v in summary.items() if k!='student_candidate'},indent=2))

if __name__=='__main__':main()
