import unittest
import numpy as np
import base64
import cv2
from types import SimpleNamespace
from unittest.mock import patch
from mask_quality import reconcile_silhouettes, constrain_paint, quality_reason, red_lamp_refinement, has_exterior_evidence

class MaskSafetyTests(unittest.TestCase):
    def test_exterior_landmark_must_belong_to_selected_instance(self):
        import torch
        silhouette=np.zeros((40,40),np.uint8);silhouette[:,:20]=1
        outside=np.zeros((1,40,40),np.float32);outside[:,:,25:]=1
        result=SimpleNamespace(boxes=SimpleNamespace(cls=torch.tensor([0]),conf=torch.tensor([.95])),
                               masks=SimpleNamespace(data=torch.tensor(outside)))
        self.assertFalse(has_exterior_evidence(result,{0:'right_front-wheel'},silhouette))
        result.masks.data=torch.tensor(np.flip(outside,axis=2).copy())
        self.assertTrue(has_exterior_evidence(result,{0:'right_front-wheel'},silhouette))
        self.assertFalse(has_exterior_evidence(result,{0:'hood'},silhouette))

    def test_red_body_is_not_a_taillight(self):
        frame=np.zeros((100,100,3),np.uint8);frame[:]=[20,20,180]
        lamps=np.zeros((100,100),np.uint8);lamps[10:20,10:30]=255
        result=red_lamp_refinement(frame,lamps,np.ones((100,100),np.uint8))
        self.assertTrue(result[15,15])
        self.assertFalse(result[60,60])
        self.assertFalse(red_lamp_refinement(frame,lamps*0,np.ones_like(lamps)).any())

    def test_missing_capture_id_does_not_reuse_another_cars_cache(self):
        import live_segment_worker as worker
        with patch.dict(worker.FRAME_CACHE, {'other-car': {'ts':1}}, clear=True):
            self.assertIsNone(worker.cache_get_frame('missing-capture'))

    def test_partial_detector_does_not_truncate_good_sam_outline(self):
        sam=np.zeros((100,100),np.uint8);sam[10:90,20:80]=1
        partial=np.zeros_like(sam);partial[70:90,20:80]=1
        result=reconcile_silhouettes(sam,partial,[20,10,79,89])
        self.assertGreater(result.sum(),partial.sum()*3)
        self.assertFalse(result[:10].any())

    def test_unrelated_sam_mask_is_rejected(self):
        sam=np.zeros((100,100),np.uint8);sam[10:30,10:30]=1
        vehicle=np.zeros_like(sam);vehicle[60:90,60:90]=1
        np.testing.assert_array_equal(reconcile_silhouettes(sam,vehicle,[0,0,99,99]),vehicle)

    def test_protected_plate_and_background_cannot_be_repaired_into_paint(self):
        paint=np.full((80,80),255,np.uint8)
        silhouette=np.zeros_like(paint);silhouette[10:70,10:70]=1
        plate=np.zeros_like(paint,bool);plate[30:40,30:50]=True
        out=constrain_paint(paint,silhouette,plate)
        self.assertFalse(out[plate].any());self.assertFalse(out[:10].any())

    def test_hd_sliver_rejected_without_authorizing_glass(self):
        silhouette=np.ones((100,100),np.uint8)
        paint=np.zeros((100,100),np.uint8);paint[95:]=255
        self.assertEqual(quality_reason(paint,silhouette),'partial-body-mask')
        self.assertIsNone(quality_reason(paint,silhouette,'hood'))

    def test_no_vehicle_endpoint_never_calls_colour_fallback(self):
        import live_segment_worker as worker
        frame=np.full((160,240,3),110,np.uint8)
        payload=base64.b64encode(cv2.imencode('.jpg',frame)[1]).decode()
        model=SimpleNamespace(predict=lambda *a,**kw:[SimpleNamespace(masks=None,boxes=[])])
        with patch.object(worker,'get_sam2_model',return_value=None), \
             patch.object(worker,'get_parts_model',return_value=None), \
             patch.object(worker,'fallback_center_panel_mask',side_effect=AssertionError('unsafe fallback')):
            result=worker.process_frame(model,payload,hd_mode=True)
        self.assertFalse(result['ok'])

if __name__=='__main__':unittest.main()
