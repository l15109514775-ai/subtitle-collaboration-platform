"""Wrap only the random backup encryption key with Windows CurrentUser DPAPI."""
import ctypes,sys
from ctypes import wintypes
class Blob(ctypes.Structure):
 _fields_=[('cbData',wintypes.DWORD),('pbData',ctypes.POINTER(ctypes.c_byte))]
def protect(data,unprotect=False):
 buf=ctypes.create_string_buffer(data);src=Blob(len(data),ctypes.cast(buf,ctypes.POINTER(ctypes.c_byte)));dst=Blob()
 crypt=ctypes.windll.crypt32
 if unprotect:ok=crypt.CryptUnprotectData(ctypes.byref(src),None,None,None,None,1,ctypes.byref(dst))
 else:ok=crypt.CryptProtectData(ctypes.byref(src),'Subtitle encrypted backup',None,None,None,1,ctypes.byref(dst))
 if not ok:raise ctypes.WinError()
 try:return ctypes.string_at(dst.pbData,dst.cbData)
 finally:ctypes.windll.kernel32.LocalFree(dst.pbData)
if __name__=='__main__':sys.stdout.buffer.write(protect(sys.stdin.buffer.read(),sys.argv[1]=='unprotect'))
