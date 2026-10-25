import tempfile
import unittest
from pathlib import Path
import cv2
import numpy as np
from active_learning import enqueue, approve, records, train

class LearningTests(unittest.TestCase):
    def test_unreviewed_predictions_cannot_train(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);image=root/'source.png'
            cv2.imwrite(str(image),np.zeros((32,32,3),np.uint8))
            enqueue(root/'queue',image,None,'scene-a','failure','model-v1')
            with self.assertRaises(ValueError):train(root/'queue',root/'candidate',1)

    def test_same_scene_cannot_leak_into_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);mask=root/'mask.png';cv2.imwrite(str(mask),np.ones((32,32),np.uint8))
            ids=[]
            for i in range(2):
                image=root/f'{i}.png';cv2.imwrite(str(image),np.full((32,32,3),50+i,np.uint8))
                ids.append(enqueue(root/'queue',image,None,'same-scene','failure','v1').name)
            approve(root/'queue',ids[0],mask,'test reviewer','same-scene','train')
            with self.assertRaises(ValueError):approve(root/'queue',ids[1],mask,'test reviewer','same-scene','validation')

    def test_actual_supervised_training_and_export_smoke(self):
        # Synthetic smoke data verifies execution only, not real-car model accuracy.
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            for i in range(4):
                image=np.full((48,64,3),20+i*20,np.uint8);image[12:36,16:48]=[80,120,180]
                labels=np.zeros((48,64),np.uint8);labels[12:36,16:48]=1;labels[12:20,22:42]=2
                ip=root/f'i{i}.png';mp=root/f'm{i}.png'
                cv2.imwrite(str(ip),image);cv2.imwrite(str(mp),labels)
                sample=enqueue(root/'queue',ip,None,f'scene-{i}','synthetic smoke','test')
                approve(root/'queue',sample.name,mp,'synthetic-test',f'scene-{i}','train' if i<2 else 'validation')
            report=train(root/'queue',root/'candidate',2)
            self.assertTrue((root/'candidate/candidate.onnx').is_file())
            self.assertFalse(report['approved_for_release'])
            self.assertGreater(report['validation_union_pixels'],0)

if __name__=='__main__':unittest.main()
