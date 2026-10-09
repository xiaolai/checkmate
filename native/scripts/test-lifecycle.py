import json,os,pathlib,subprocess,sys,tempfile,time
root=pathlib.Path.cwd();evidence=pathlib.Path(os.environ['CHECKMATE_EVIDENCE_DIR']);state=pathlib.Path(tempfile.mkdtemp(prefix='checkmate-lifecycle-'));app=root/'build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative';ax=evidence/'ax-helper'
subprocess.run(['xcrun','swiftc','Tools/ax-helper.swift','-o',str(ax)],check=True)
env=dict(os.environ,CHECKMATE_AUTOMATION='1');args=[str(app),'--automation','--data-dir',str(state)];process=None

def act(action,target=''):
 try:return subprocess.check_output([str(ax),str(process.pid),action,target],text=True)
 except subprocess.CalledProcessError as error:print(error.output,flush=True);raise
def wait(predicate,timeout=10):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  if predicate():return
  time.sleep(.05)
 raise AssertionError('Lifecycle condition timed out')
try:
 start=time.monotonic();process=subprocess.Popen(args,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);wait(lambda:'Chessboard' in act('list'));warm=time.monotonic()-start;assert warm<2,warm
 act('fullscreen');time.sleep(2);act('press','Toggle Sidebar');time.sleep(.9);act('fullscreen');time.sleep(2);act('press','Toggle Sidebar');time.sleep(.9)
 act('drag');moved_x=float(act('position-x'));act('press','Toggle Sidebar');time.sleep(.9);act('press','Toggle Sidebar');time.sleep(.9);assert abs(float(act('position-x'))-moved_x)<=1,(moved_x,act('position-x'))
 time.sleep(.3);assert abs(json.loads((state/'state-v1.json').read_text())['window']['frame'][0]-moved_x)<=1
 duplicate=subprocess.Popen(args,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);duplicate.wait(timeout=5);assert process.poll() is None;assert act('windows').splitlines()[0]=='1'
 act('press','Settings');wait(lambda:'Settings' in act('windows'));act('press','Settings');assert act('windows').splitlines()[0]=='2';act('close-settings')
 act('press','e2, White, pawn');act('press','e4, move destination');time.sleep(1.2)
 act('quit');process.wait(timeout=5);saved=json.loads((state/'state-v1.json').read_text());assert saved['practice']['pgn'];pgn=saved['practice']['pgn'];process=subprocess.Popen(args,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);wait(lambda:'e4, White, pawn' in act('list'));assert json.loads((state/'state-v1.json').read_text())['practice']['pgn']==pgn
 result={'passed':True,'warmInteractiveSeconds':warm,'singleInstance':True,'settingsSingleton':True,'titlebarDrag':True,'dragAfterFullscreenPersists':True,'gameRestart':True};(evidence/'lifecycle-results.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
finally:
 if process and process.poll() is None:process.terminate();process.wait(timeout=5)
