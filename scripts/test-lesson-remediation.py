"""Silent build-host real-pointer checks for lesson activity handoffs, practice forks and promotion."""
import json,os,pathlib,shutil,socket,subprocess,tempfile,time
if not any(n in socket.gethostname().lower() for n in ['build-host','build-host']):raise SystemExit('Run on build-host only')
root=pathlib.Path(__file__).resolve().parents[1];evidence=pathlib.Path(os.environ['CHECKMATE_EVIDENCE_DIR']);evidence.mkdir(parents=True,exist_ok=True)
helpers={}
for name in ['pointer-helper','ax-helper']:
 helpers[name]=evidence/name;subprocess.run(['xcrun','swiftc',str(root/'Tools'/f'{name}.swift'),'-o',str(helpers[name])],check=True)
state=pathlib.Path(tempfile.mkdtemp(prefix='checkmate-lessons-pointer-'));process=None
command=[str(root/'build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative'),'--automation','--data-dir',str(state)]
env={k:v for k,v in os.environ.items() if k!='CHECKMATE_AUTOMATION'}
def pointer(*args):return subprocess.check_output([str(helpers['pointer-helper']),str(process.pid),*args],text=True).strip()
def listing():return subprocess.check_output([str(helpers['ax-helper']),str(process.pid),'list'],text=True)
def wait(test,message,timeout=20):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  if test():return
  time.sleep(.2)
 raise AssertionError(message)
def saved():return json.loads((state/'state-v1.json').read_text())
def stop():
 global process
 if process:process.terminate();process.wait(timeout=10);process=None
 time.sleep(.4)
def launch():
 global process
 process=subprocess.Popen(command,env=env,stdout=subprocess.DEVNULL,stderr=(evidence/"lesson-pointer-trace.log").open("ab"))
 wait(lambda:'Chessboard' in listing(),'Board did not appear');time.sleep(1)
results={}
try:
 launch()
 if 'AXStaticText: The Pawn' not in listing():pointer('click','Toggle Sidebar')
 wait(lambda:'AXStaticText: The Pawn' in listing(),'Sidebar did not open')
 if 'Your next move.' not in listing():pointer('click','Toggle Game Details')
 wait(lambda:'Your next move.' in listing(),'Details did not open')
 pointer('click-square','e2');pointer('click-square','e4')
 wait(lambda:'1. e4 ' in saved()['practice']['pgn'] and saved()['practice']['fen'].split()[1]=='w','Computer did not reply')
 old=saved()['practice']['pgn']
 pointer('click','Pawn Duel');wait(lambda:'Play Pawn Duel' in listing(),'Visible game invitation missing')
 pointer('click','Play Pawn Duel');wait(lambda:'Your turn' in listing(),'Play button did not start game')
 wait(lambda:pointer('label','e2').startswith('e2, White, pawn'),'Mini-game board did not appear')
 time.sleep(.8)
 pointer('click-square','e2')
 (evidence/'mini-selection-ax.txt').write_text(listing())
 wait(lambda:'selected' in pointer('label','e2'),'Mini-game pawn did not select')
 wait(lambda:'move destination' in pointer('label','e4'),'Mini-game destinations did not appear')
 pointer('click-square','e4')
 (evidence/'mini-move-ax.txt').write_text(listing())
 wait(lambda:len(saved().get('miniGames',{}).get('pawn-duel',{}).get('history',[]))>=2,'Mini-game computer did not reply')
 results['activityPointerAndComputer']=True
 # The outline exposes offscreen row labels too; real wheel input makes the row clickable.
 pointer('scroll-sidebar','-120')
 time.sleep(.5)
 (evidence/'practice-invitation-ax.txt').write_text(listing())
 pointer('click','The Fork');wait(lambda:'Try it against the computer' in listing(),'Practice invitation missing')
 pointer('click','Try it against the computer');wait(lambda:pointer('label','b5').startswith('b5, White, knight'),'Practice button did not install position')
 wait(lambda:saved()['practice'].get('previousGame')==old,'Lesson practice lost previous game')
 results['practicePointerAndPreviousGame']=True
 stop()
 value=saved();fen='7k/4P3/8/8/8/8/8/K7 w - - 0 1'
 value['practice']['pgn']='[SetUp "1"]\n[FEN "'+fen+'"]\n\n*';value['practice']['fen']=fen;value['practice']['ending']=None
 value['settings']['voiceAutoConnect']=False;value['settings']['companionAutoStart']=False
 (state/'state-v1.json').write_text(json.dumps(value))
 launch();pointer('click-square','e7');pointer('click-square','e8')
 wait(lambda:pointer('menu-open','Knight')=='true','Native promotion menu did not open')
 subprocess.run(['/usr/sbin/screencapture','-x',str(evidence/'promotion-menu.png')],check=True)
 pointer('choose-menu-item','Knight')
 wait(lambda:pointer('label','e8').startswith('e8, White, knight'),'Knight menu choice did not promote')
 results['promotionPointer']=True
 results['silent']=True
 # Reached only when every check above passed.
 results['passed']=True
 (evidence/'lesson-remediation-results.json').write_text(json.dumps(results,indent=2))
 print(json.dumps(results))
except Exception:
 (evidence/'lesson-failure-ax.txt').write_text(listing())
 subprocess.run(['/usr/sbin/screencapture','-x',str(evidence/'lesson-failure.png')],check=True)
 raise
finally:
 stop()
 # The app is stopped first; run-gates fails a gate that leaves temporary files.
 shutil.rmtree(state,ignore_errors=True)
