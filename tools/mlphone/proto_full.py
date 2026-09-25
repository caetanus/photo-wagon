# Full phone pipeline prototype @640, validated against OpenCV(YuNet+alignCrop)+r100.
import cv2, numpy as np, tensorflow as tf, math, onnxruntime as ort
SZ=640
img=cv2.resize(cv2.imread('tools/mlphone/testface_1024.jpg'),(SZ,SZ))   # BGR 640

# ---------- reference (OpenCV) ----------
det=cv2.FaceDetectorYN.create('models/face_detection_yunet_2023mar.onnx','',(SZ,SZ),0.6,0.3,5000)
det.setInputSize((SZ,SZ)); _,ref=det.detect(img); r=ref[0]
ref_lmk=np.array(r[4:14],np.float32).reshape(5,2)
ref_aligned=cv2.FaceRecognizerSF.create('models/face_recognition_sface_2021dec.onnx','').alignCrop(img,r)  # 112 BGR
r100=ort.InferenceSession('models/arcfaceresnet100-8.onnx',providers=['CPUExecutionProvider'])
def emb_onnx(bgr112):
    blob=cv2.dnn.blobFromImage(bgr112,1.0,(112,112),(0,0,0),swapRB=True,crop=False)
    e=r100.run(None,{r100.get_inputs()[0].name:blob})[0].reshape(-1); return e/np.linalg.norm(e)
ref_emb=emb_onnx(ref_aligned)

# ---------- mine: TFLite decode ----------
it=tf.lite.Interpreter('models/tflite/yunet/face_detection_yunet_2023mar_float32.tflite'); it.allocate_tensors()
ind=it.get_input_details()[0]
it.set_tensor(ind['index'],img.astype('float32')[None]); it.invoke()   # YuNet wants BGR (OpenCV swapRB=false)
outs=[it.get_tensor(d['index'])[0] for d in it.get_output_details()]
byN={}
for t in outs:
    N,k=t.shape; g=byN.setdefault(N,{'s':[],'b':None,'k':None})
    (g['s'].append(t.reshape(-1)) if k==1 else g.__setitem__('b',t) if k==4 else g.__setitem__('k',t))
STR={6400:8,1600:16,400:32}
def decode(conf=0.6):
    F=[]
    for N,g in byN.items():
        s=STR[N]; cols=SZ//s; sc=np.sqrt(np.clip(g['s'][0]*g['s'][1],0,None)); b=g['b']; k=g['k']
        for idx in np.where(sc>conf)[0]:
            rr=idx//cols; cc=idx%cols
            cx=(cc+b[idx,0])*s; cy=(rr+b[idx,1])*s; w=math.exp(b[idx,2])*s; h=math.exp(b[idx,3])*s
            lm=[(cc+k[idx,2*j])*s for j2 in [0] for j in range(5) for _ in [0]]  # placeholder
            lm=[]
            for j in range(5): lm+=[(cc+k[idx,2*j])*s,(rr+k[idx,2*j+1])*s]
            F.append([cx-w/2,cy-h/2,w,h,float(sc[idx])]+lm)
    return F
def nms(F,iou=0.3):
    F=sorted(F,key=lambda f:-f[4]); K=[]
    def IOU(a,b):
        ix1,iy1=max(a[0],b[0]),max(a[1],b[1]); ix2,iy2=min(a[0]+a[2],b[0]+b[2]),min(a[1]+a[3],b[1]+b[3])
        inter=max(0,ix2-ix1)*max(0,iy2-iy1); return inter/(a[2]*a[3]+b[2]*b[3]-inter+1e-9)
    for f in F:
        if all(IOU(f,k)<iou for k in K): K.append(f)
    return K
mine=nms(decode())[0]
my_lmk=np.array(mine[5:15],np.float32).reshape(5,2)

# ---------- alignment (ArcFace canonical 5-pt template) ----------
TEMPLATE=np.array([[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],
                   [41.5493,92.3655],[70.7299,92.2041]],np.float32)
def umeyama(src,dst):
    n=len(src); sm=src.mean(0); dm=dst.mean(0); sd=src-sm; dd=dst-dm
    A=(dd.T@sd)/n; U,S,Vt=np.linalg.svd(A); D=np.ones(2)
    if np.linalg.det(U)*np.linalg.det(Vt)<0: D[-1]=-1
    R=U@np.diag(D)@Vt; scale=(S*D).sum()/((sd**2).sum()/n)
    M=np.zeros((2,3),np.float32); M[:2,:2]=scale*R; M[:,2]=dm-scale*R@sm
    return M
def align(bgr,lmk):
    M=umeyama(lmk.astype(np.float64),TEMPLATE.astype(np.float64))
    return cv2.warpAffine(bgr,M,(112,112),flags=cv2.INTER_LINEAR)

# (a) my align with REF landmarks vs OpenCV alignCrop
my_align_reflmk=align(img,ref_lmk)
d_align=float(np.mean(np.abs(my_align_reflmk.astype(int)-ref_aligned.astype(int))))
cos_align=float(np.dot(emb_onnx(my_align_reflmk),ref_emb))
# (b) end-to-end: my landmarks -> my align -> r100
my_emb=emb_onnx(align(img,my_lmk))
cos_e2e=float(np.dot(my_emb,ref_emb))
lmk_err=float(np.mean(np.linalg.norm(my_lmk-ref_lmk,axis=1)))

# definitive: my aligned crop -> TFLite r100 fp16 (the phone's actual model)
r100t=tf.lite.Interpreter('models/tflite/r100/r100_float16.tflite'); r100t.allocate_tensors()
ri,ro=r100t.get_input_details()[0],r100t.get_output_details()[0]
def emb_tflite(bgr112):
    rgb=cv2.cvtColor(bgr112,cv2.COLOR_BGR2RGB).astype('float32')[None]
    r100t.set_tensor(ri['index'],rgb); r100t.invoke()
    e=r100t.get_tensor(ro['index']).reshape(-1); return e/np.linalg.norm(e)
cos_phone=float(np.dot(emb_tflite(align(img,my_lmk)),ref_emb))
print(f"*** FULL PHONE PIPELINE (TFLite YuNet+decode+Umeyama+TFLite r100 fp16) vs desktop = {cos_phone:.5f} ***")
print(f"landmark mean err (mine vs opencv) = {lmk_err:.2f}px")
print(f"(a) my-align(ref-lmk) vs alignCrop: mean|Δpix|={d_align:.2f}  emb-cos={cos_align:.5f}")
print(f"(b) END-TO-END my decode+align+r100 vs reference emb  COS = {cos_e2e:.5f}")
print("    "+("EXCELLENT" if cos_e2e>0.97 else "OK-ish" if cos_e2e>0.9 else "TOO LOW - fix align/decode"))
