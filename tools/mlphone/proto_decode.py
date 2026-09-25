# Prototype + validate the YuNet decode against OpenCV at the SAME 640x640 input.
import cv2, numpy as np, tensorflow as tf, math, sys

SZ=640
img0=cv2.imread('tools/mlphone/testface_1024.jpg')          # 768x1024 BGR
img=cv2.resize(img0,(SZ,SZ))                                 # square 640 (matches TFLite input)

# --- reference: OpenCV YuNet at 640x640 ---
det=cv2.FaceDetectorYN.create('models/face_detection_yunet_2023mar.onnx','',(SZ,SZ),0.6,0.3,5000)
det.setInputSize((SZ,SZ)); _,ref=det.detect(img)
print("OpenCV@640:", 0 if ref is None else len(ref),"faces")
if ref is not None:
    r=ref[0]; print("  ref bbox=",[round(float(v),1) for v in r[:4]],"score=",round(float(r[14]),3),
                     "lmk0=",[round(float(v),1) for v in r[4:6]])

# --- mine: TFLite YuNet + decode ---
it=tf.lite.Interpreter('models/tflite/yunet/face_detection_yunet_2023mar_float32.tflite'); it.allocate_tensors()
ind=it.get_input_details()[0]
x=cv2.cvtColor(img,cv2.COLOR_BGR2RGB).astype('float32')[None]   # RGB 0-255 NHWC
it.set_tensor(ind['index'],x); it.invoke()
outs=[it.get_tensor(d['index'])[0] for d in it.get_output_details()]   # each [N, k]

# group by stride N -> {N: {'score':[t1,t2],'bbox':t,'kps':t}}
byN={}
for t in outs:
    N,k=t.shape
    g=byN.setdefault(N,{'score':[],'bbox':None,'kps':None})
    if k==1: g['score'].append(t.reshape(-1))
    elif k==4: g['bbox']=t
    elif k==10: g['kps']=t
STRIDE={6400:8,1600:16,400:32}

def decode(conf=0.6, use_sqrt=True):
    faces=[]
    for N,g in byN.items():
        s=STRIDE[N]; cols=SZ//s; rows=SZ//s
        cls,obj=g['score'][0],g['score'][1]
        prod=cls*obj
        sc=np.sqrt(np.clip(prod,0,None)) if use_sqrt else prod
        bbox=g['bbox']; kps=g['kps']
        for idx in np.where(sc>conf)[0]:
            r=idx//cols; c=idx%cols
            cx=(c+bbox[idx,0])*s; cy=(r+bbox[idx,1])*s
            w=math.exp(bbox[idx,2])*s; h=math.exp(bbox[idx,3])*s
            lmk=[]
            for kk in range(5): lmk+= [(c+kps[idx,2*kk])*s,(r+kps[idx,2*kk+1])*s]
            faces.append([cx-w/2,cy-h/2,w,h,float(sc[idx])]+lmk)
    return faces

def nms(faces,iou=0.3):
    if not faces: return []
    faces=sorted(faces,key=lambda f:-f[4]); keep=[]
    def IOU(a,b):
        ax2,ay2=a[0]+a[2],a[1]+a[3]; bx2,by2=b[0]+b[2],b[1]+b[3]
        ix1,iy1=max(a[0],b[0]),max(a[1],b[1]); ix2,iy2=min(ax2,bx2),min(ay2,by2)
        iw,ih=max(0,ix2-ix1),max(0,iy2-iy1); inter=iw*ih
        return inter/(a[2]*a[3]+b[2]*b[3]-inter+1e-9)
    for f in faces:
        if all(IOU(f,k)<iou for k in keep): keep.append(f)
    return keep

for us in (True,False):
    d=nms(decode(0.6,us))
    tag="sqrt(cls*obj)" if us else "cls*obj"
    print(f"mine[{tag}]: {len(d)} faces", end="")
    if d:
        f=d[0]; print("  bbox=",[round(v,1) for v in f[:4]],"score=",round(f[4],3),"lmk0=",[round(v,1) for v in f[5:7]])
    else: print()
