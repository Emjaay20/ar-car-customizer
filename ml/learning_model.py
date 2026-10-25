"""Small supervised semantic candidate. Not installed until evaluated/reviewed."""
import torch
from torch import nn
from torch.nn import functional as F

def block(inp,out,stride=1):
    return nn.Sequential(nn.Conv2d(inp,inp,3,stride,1,groups=inp),nn.ReLU(),nn.Conv2d(inp,out,1),nn.ReLU())

class WrapStudent(nn.Module):
    def __init__(self):
        super().__init__()
        self.stem=nn.Sequential(nn.Conv2d(3,16,3,2,1),nn.ReLU())
        self.low=block(16,24,2);self.mid=block(24,48,2);self.high=block(48,64,2)
        self.decode=nn.Sequential(nn.Conv2d(64+24,32,3,1,1),nn.ReLU(),nn.Conv2d(32,3,1))
    def forward(self,x):
        low=self.low(self.stem(x));high=self.high(self.mid(low))
        logits=self.decode(torch.cat([low,F.interpolate(high,size=low.shape[-2:],mode='bilinear',align_corners=False)],1))
        return F.interpolate(logits,size=x.shape[-2:],mode='bilinear',align_corners=False)

class BodyExport(nn.Module):
    def __init__(self,model):super().__init__();self.model=model
    def forward(self,x):
        p=torch.softmax(self.model(x),dim=1)[:,1:2]
        return torch.clamp((p-.5)*2,0,1)
