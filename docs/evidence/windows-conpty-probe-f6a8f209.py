from pathlib import Path
import subprocess,os,time,json,re
root=Path.home()/".cache/hw-f6a8-18e5b545"
exe=root/"heimdall-m3b-f6a8f209/tools/pty_host/target/debug/ham-pty-host.exe"
sock=root/"native.sock"
env={k:v for k,v in os.environ.items() if not k.startswith("HEIMDALL_")}
def ctl(*args,check=True):
 p=subprocess.run([str(exe),"--socket",str(sock),*args],env=env,text=True,capture_output=True,timeout=15)
 print(json.dumps(dict(args=list(args),exit=p.returncode,out=p.stdout,err=p.stderr)))
 if check and p.returncode:raise RuntimeError("private daemon control failed")
 return p.stdout
log=(root/"conpty-daemon.log").open("w")
daemon=subprocess.Popen([str(exe),"--socket",str(sock),"daemon"],env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log)
child=None
try:
 for _ in range(100):
  if sock.exists():break
  if daemon.poll() is not None:raise RuntimeError("daemon exited")
  time.sleep(.1)
 out=ctl("spawn","--instance","win_native_f6a8","--cwd",str(root),"--timeout-seconds","10","--",os.environ["COMSPEC"],"/d","/c","echo","NATIVE_CONPTY_F6A8")
 child=int(re.search(r"pid (\d+)",out)[1])
 time.sleep(1)
 capture=ctl("capture","--instance","win_native_f6a8")
 assert "NATIVE_CONPTY_F6A8" in capture
 print(json.dumps(dict(status="native_conpty_capture_pass",child=child,daemon=daemon.pid)))
 ctl("close","--instance","win_native_f6a8")
 assert "(no agents)" in ctl("list")
finally:
 try:ctl("stop",check=False)
 except Exception as e:print(type(e).__name__)
 try:daemon.wait(timeout=10)
 except subprocess.TimeoutExpired:
  daemon.terminate();daemon.wait(timeout=5)
 log.close()
 print(json.dumps(dict(daemon_exit=daemon.returncode,socket_exists=sock.exists(),child=child)))
 print((root/"conpty-daemon.log").read_text())
