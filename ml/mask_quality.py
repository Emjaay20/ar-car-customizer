"""Instance-safe mask composition, independent of model runtime."""
import cv2
import numpy as np

def has_exterior_evidence(result, names, silhouette):
    """Require a credible exterior landmark belonging to the selected instance.

    This conservative operating mode abstains on unsupported cabin/panel-only views.
    It is not an interior classifier and needs held-out testing.
    """
    if result is None or result.masks is None or result.boxes is None:
        return False
    h,w=silhouette.shape[:2]
    for i,c in enumerate(result.boxes.cls):
        name=names[int(c)]
        if not any(t in name for t in ('wheel','headlight','tail-light','grille','license')):
            continue
        if float(result.boxes.conf[i]) < .35:
            continue
        mask=cv2.resize(result.masks.data[i].cpu().numpy(),(w,h))>.5
        overlap=np.count_nonzero(mask & (silhouette>0))/max(1,np.count_nonzero(mask))
        if overlap>.5:return True
    return False

def red_lamp_refinement(frame, lamp_support, silhouette):
    """Colour can refine a detected lamp, but cannot label red bodywork a lamp."""
    b,g,r=cv2.split(frame.astype(np.int16))
    red=(r-g>28)&(r-b>28)&(r>70)
    support=cv2.dilate((lamp_support>0).astype(np.uint8),np.ones((3,3),np.uint8))>0
    return (red & support & (silhouette>0)).astype(np.uint8)*255

def binary(mask):
    return (mask > (32 if mask.max(initial=0) > 1 else .2)).astype(np.uint8)

def reconcile_silhouettes(sam, vehicle, box):
    """Keep a good SAM outline when YOLO is partial, bounded by its detected box.

    A contour and a box serve different purposes: a poor contour must not erase
    a better outline, and a prompt box must never authorize the entire rectangle.
    """
    s, v = binary(sam), binary(vehicle)
    support = cv2.dilate(v, np.ones((7, 7), np.uint8))
    retained = np.count_nonzero(s & support) / max(1, np.count_nonzero(s))
    if retained >= .75:
        return s & support
    x0,y0,x1,y1 = [int(round(x)) for x in box]
    h,w=s.shape
    roi=np.zeros_like(s)
    roi[max(0,y0):min(h,y1+1),max(0,x0):min(w,x1+1)]=1
    candidate=s & roi
    # Require actual overlap with semantic vehicle evidence.
    if np.count_nonzero(candidate & v) < .1*max(1,np.count_nonzero(v)):
        return v
    return candidate

def validated_parts_fallback(result, names, shape):
    """Require multiple coherent body classes, never a colour-only seed."""
    if result.masks is None or result.boxes is None:
        return None
    masks=[];classes=set()
    for i,c in enumerate(result.boxes.cls):
        name=names[int(c)]
        if any(t in name for t in ('window','windshield','wheel','light','license','grille','mirror')):
            continue
        if float(result.boxes.conf[i]) < .38:
            continue
        region=cv2.resize(result.masks.data[i].cpu().numpy(),(shape[1],shape[0]))>.5
        masks.append(region);classes.add(int(c))
    if len(classes)<2:
        return None
    union=np.logical_or.reduce(masks).astype(np.uint8)
    count,labels,stats,_=cv2.connectedComponentsWithStats(union,8)
    if count<2:return None
    idx=1+int(np.argmax(stats[1:,cv2.CC_STAT_AREA]))
    component=labels==idx
    if np.count_nonzero(component)<.01*union.size:return None
    # Each independent class must support the same region.
    if sum(np.any(m & component) for m in masks)<2:return None
    return component.astype(np.uint8)

def constrain_paint(paint, silhouette, plate=None):
    result=paint.copy()
    result[binary(silhouette)==0]=0
    if plate is not None:result[plate.astype(bool)]=0
    return result

def quality_reason(paint, silhouette, panel='body'):
    area=np.count_nonzero(binary(silhouette))
    painted=np.count_nonzero(paint>64)
    if painted<200:return 'insufficient-paint'
    # Conservative guard only; small valid panel requests are evaluated separately.
    if panel=='body' and area>400 and painted/area<.12:
        return 'partial-body-mask'
    return None
