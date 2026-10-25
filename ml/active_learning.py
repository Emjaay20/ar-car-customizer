"""Local active-learning queue and supervised candidate training.

Predictions are NEVER ground truth. Only explicitly reviewed 0=background,
1=paintable body, 2=protected-part, 255=ignore annotations enter training.
Scenes must be split before training. Candidate exports are not installed.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path
import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def read_record(folder):
    record=json.loads((folder/'sample.json').read_text(encoding='utf8'))
    record['folder']=folder
    return record

def records(root):
    return [read_record(p.parent) for p in sorted(root.glob('*/sample.json'))]

def approve(root,sample,mask,reviewer,scene,split):
    folder=root/sample
    record=read_record(folder)
    image=cv2.imread(str(folder/'image.png'))
    labels=cv2.imread(str(mask),cv2.IMREAD_UNCHANGED)
    if image is None or labels is None or labels.ndim!=2 or labels.dtype!=np.uint8 or labels.shape!=image.shape[:2]:
        raise ValueError('Annotation must be a single-channel image matching source dimensions')
    if not set(np.unique(labels)).issubset({0,1,2,255}):raise ValueError('Use class values 0,1,2,255')
    if not np.any(labels!=255):raise ValueError('Annotation has no reviewed pixels')
    if not reviewer.strip() or not scene.strip():raise ValueError('Reviewer and scene required')
    for other in records(root):
        if other.get('reviewed') and other.get('scene')==scene and other['split']!=split:
            raise ValueError('The same scene cannot appear in training and validation')
        if other.get('reviewed') and other.get('image_sha256')==record.get('image_sha256') and other['split']!=split:
            raise ValueError('Duplicate image across splits')
    cv2.imwrite(str(folder/'labels.png'),labels)
    record.pop('folder',None)
    record.update(reviewed=True,reviewer=reviewer,scene=scene,split=split,label_sha256=digest(folder/'labels.png'))
    (folder/'sample.json').write_text(json.dumps(record,indent=2),encoding='utf8')

def enqueue(root,image,prediction,scene,reason,model):
    root.mkdir(parents=True,exist_ok=True)
    im=cv2.imread(str(image))
    if im is None:raise ValueError('Invalid source image')
    identity=digest(image)[:24]
    folder=root/identity
    if folder.exists():return folder
    folder.mkdir()
    cv2.imwrite(str(folder/'image.png'),im)
    if prediction:shutil.copyfile(prediction,folder/'prediction.png')
    record={'id':identity,'image_sha256':digest(folder/'image.png'),'scene':scene,'reason':reason,
            'model':model,'reviewed':False,'prediction_is_ground_truth':False}
    (folder/'sample.json').write_text(json.dumps(record,indent=2),encoding='utf8')
    return folder

def train(root,out,epochs,baseline=None):
    if epochs < 1:raise ValueError('Epochs must be positive')
    import torch
    from torch import nn
    from torch.utils.data import Dataset,DataLoader
    from learning_model import WrapStudent, BodyExport
    torch.manual_seed(17);torch.set_num_threads(4)
    reviewed=[r for r in records(root) if r.get('reviewed')]
    train_rows=[r for r in reviewed if r['split']=='train']
    val_rows=[r for r in reviewed if r['split']=='validation']
    if len({r['scene'] for r in train_rows})<2 or len({r['scene'] for r in val_rows})<2:
        raise ValueError('Need reviewed masks from >=2 training scenes AND >=2 held-out validation scenes')
    if {r['scene'] for r in train_rows}&{r['scene'] for r in val_rows}:raise ValueError('Scene leakage')
    for r in reviewed:
        if digest(r['folder']/'labels.png')!=r['label_sha256']:raise ValueError('Annotation changed after review')
        if digest(r['folder']/'image.png')!=r['image_sha256']:raise ValueError('Source changed after review')
    class Samples(Dataset):
        def __init__(self,rows):self.rows=rows
        def __len__(self):return len(self.rows)
        def __getitem__(self,i):
            folder=self.rows[i]['folder']
            image=cv2.cvtColor(cv2.imread(str(folder/'image.png')),cv2.COLOR_BGR2RGB)
            labels=cv2.imread(str(folder/'labels.png'),0)
            x=cv2.resize(image,(384,384)).transpose(2,0,1).astype(np.float32)/255
            y=cv2.resize(labels,(384,384),interpolation=cv2.INTER_NEAREST).astype(np.int64)
            return torch.from_numpy(x),torch.from_numpy(y)
    model=WrapStudent();optim=torch.optim.AdamW(model.parameters(),lr=.001)
    loss_fn=nn.CrossEntropyLoss(ignore_index=255)
    loader=DataLoader(Samples(train_rows),batch_size=2,shuffle=True)
    history=[]
    for epoch in range(epochs):
        model.train();losses=[]
        for x,y in loader:
            if not torch.any(y!=255):continue
            optim.zero_grad();loss=loss_fn(model(x),y);loss.backward();optim.step();losses.append(float(loss.detach()))
        history.append({'epoch':epoch+1,'loss':float(np.mean(losses))})
        print(history[-1],flush=True)
    model.eval();intersection=union=spill=protected=0
    baseline_intersection=baseline_union=baseline_spill=0
    baseline_session=None
    if baseline is not None:
        import onnxruntime as ort
        options=ort.SessionOptions();options.intra_op_num_threads=4
        baseline_session=ort.InferenceSession(str(baseline),sess_options=options,providers=['CPUExecutionProvider'])
    export=BodyExport(model)
    with torch.no_grad():
        for x,y in DataLoader(Samples(val_rows),batch_size=1):
            pred=export(x)[:,0]>.16;valid=y!=255;truth=y==1
            intersection+=int((pred&truth&valid).sum());union+=int(((pred|truth)&valid).sum())
            spill+=int((pred&(y==2)).sum());protected+=int((y==2).sum())
            if baseline_session is not None:
                probability=baseline_session.run(None,{baseline_session.get_inputs()[0].name:x.numpy()})[0][:,0]
                bp=torch.from_numpy(probability>.16)
                baseline_intersection+=int((bp&truth&valid).sum())
                baseline_union+=int(((bp|truth)&valid).sum())
                baseline_spill+=int((bp&(y==2)).sum())
    out.mkdir(parents=True,exist_ok=True)
    torch.save(model.state_dict(),out/'candidate.pt')
    torch.onnx.export(export,torch.zeros(1,3,384,384),str(out/'candidate.onnx'),
        input_names=['input'],output_names=['output'],opset_version=12,dynamo=False)
    report={'history':history,'body_iou':intersection/max(1,union),'protected_spill':spill/max(1,protected),
            'validation_union_pixels':union,'protected_pixels':protected,
            'train_samples':[r['id'] for r in train_rows],'validation_samples':[r['id'] for r in val_rows],
            'approved_for_release':False,'note':'Candidate only. Requires comparison with baseline, broader held-out testing and device profiling. No automatic activation.'}
    if baseline_session is not None:
        report['baseline']={'sha256':digest(baseline),'body_iou':baseline_intersection/max(1,baseline_union),
                            'protected_spill':baseline_spill/max(1,protected)}
        report['non_regression_on_this_validation_set']=(
            union>0 and protected>0 and report['body_iou']>=report['baseline']['body_iou']
            and report['protected_spill']<=report['baseline']['protected_spill'])
    (out/'evaluation.json').write_text(json.dumps(report,indent=2))
    return report

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--queue',type=Path,required=True)
    sub=parser.add_subparsers(dest='command',required=True)
    c=sub.add_parser('collect');c.add_argument('--image',type=Path,required=True);c.add_argument('--prediction',type=Path)
    c.add_argument('--scene',required=True);c.add_argument('--reason',required=True);c.add_argument('--model',required=True)
    a=sub.add_parser('approve');a.add_argument('--sample',required=True);a.add_argument('--mask',type=Path,required=True)
    a.add_argument('--reviewer',required=True);a.add_argument('--scene',required=True);a.add_argument('--split',choices=['train','validation'],required=True)
    t=sub.add_parser('train');t.add_argument('--out',type=Path,required=True);t.add_argument('--epochs',type=int,default=20)
    t.add_argument('--baseline',type=Path,required=True,help='Evaluate existing ONNX on the same held-out labels')
    sub.add_parser('stats')
    args=parser.parse_args()
    if args.command=='collect':print(enqueue(args.queue,args.image,args.prediction,args.scene,args.reason,args.model))
    elif args.command=='approve':approve(args.queue,args.sample,args.mask,args.reviewer,args.scene,args.split)
    elif args.command=='train':print(json.dumps(train(args.queue,args.out,args.epochs,args.baseline),indent=2))
    else:
        rows=records(args.queue)
        print(json.dumps({'collected':len(rows),'reviewed':sum(bool(r.get('reviewed')) for r in rows)},indent=2))

if __name__=='__main__':main()
