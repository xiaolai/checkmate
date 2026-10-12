"""Silent test-host real-pointer checks for lesson activity handoffs, practice forks and promotion."""
import json,os,pathlib,re,shutil,subprocess,tempfile,time
import test_host;test_host.require('lesson pointer acceptance')
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
 pointer('click','Try it against the computer');wait(lambda:pointer('label','g5').startswith('g5, White, knight'),'Practice button did not install position')
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
 # A lesson's arrow and check describe the position its move produces: they appear only once the rook has landed,
 # and the arrow ends on the king it attacks. Sampled while the move plays (automation playback is silent).
 stop();launch()
 if 'AXStaticText: Introduction' not in listing():pointer('click','Toggle Sidebar')
 wait(lambda:'AXStaticText: Introduction' in listing(),'Sidebar did not open')
 # A square is read only once the rook step has opened.
 def label(square):
  try:return pointer('label',square)
  except subprocess.CalledProcessError:return ''
 pointer('click','Check and Checkmate')
 if 'AXPopUpButton: Transcript' not in listing():pointer('click','Toggle Game Details')
 wait(lambda:'AXPopUpButton: Transcript' in listing(),'The Check and Checkmate transcript picker did not appear')
 pointer('select-popup','Transcript','16. A rook on the edge')
 wait(lambda:label('h1').startswith('h1, White, rook'),'The rook step did not open on its starting board')
 assert 'suggested move' not in pointer('label','h8') and 'in check' not in pointer('label','c8'),'The paused step shows overlays before its move'
 pointer('click','Play');before=0;end=time.monotonic()+20
 while True:
  # The overlay square is read first: an overlay seen before the rook square still shows no rook is a true violation,
  # while reading h8 first would let the rook land between the two reads.
  c8=pointer('label','c8');h8=pointer('label','h8');landed=h8.startswith('h8, White, rook')
  assert landed or ('suggested move' not in h8 and 'in check' not in c8),f'Overlay before the rook landed: {h8} / {c8}'
  if not landed:before+=1
  if landed and 'suggested move to c8' in h8 and 'in check' in c8:break
  assert time.monotonic()<end,f'The rook step never showed its arrow and check: {h8} / {c8}'
  time.sleep(.03)
 assert before>0,'No sample fell before the rook landed, so the order was not observed'
 assert 'suggested move' not in pointer('label','b8'),'The arrow runs past the king'
 results['lessonOverlayAfterMove']=True
 # Practice activities sit indented under their piece lesson. For each of the five: the lesson's Practise button, a real
 # click on the activity row's text and one on its indent each open it, and VoiceOver hears which lesson it practises.
 # The sidebar's width is fixed (Metrics.left), so row geometry is the same at minimum width and in fullscreen.
 # The title above the board names the lesson shown.
 def opened(title):return lambda:'Current activity | '+title in listing()
 activities=[('The Pawn','Pawn Duel'),('The Rook','Rook Practice'),('The Bishop','Bishop Practice'),('The Queen','Queen Practice'),('The Knight','Knight Practice')]
 for parent,activity in activities:
  pointer('click',parent);wait(lambda:'Practise: '+activity in listing(),f'{parent} does not offer {activity}')
  pointer('click','Practise: '+activity);wait(opened(activity),f'Practise did not open {activity}')
  pointer('click',parent);wait(lambda:'Practise: '+activity in listing(),f'The {parent} row did not open its lesson')
  pointer('click',activity);wait(opened(activity),f'A click on the {activity} row text did not open it')
  pointer('click',parent);wait(lambda:'Practise: '+activity in listing(),f'The {parent} row did not open its lesson')
  pointer('click-left',activity,'30');wait(opened(activity),f'A click on the indent of the {activity} row did not open it')
  hint=pointer('help',activity);assert hint=='Practice activity for '+parent,f'{activity} row hint: {hint!r}'
 # On a lesson's last transcript the toolbar arrow goes to the next main lesson, skipping practice; earlier it only
 # advances the transcript, and the final lesson has no next lesson.
 course=json.loads((root/'Sources/CheckmateCore/Resources/course.json').read_text())
 def steps_of(title):return course['stepTitles'][next(i for i,l in enumerate(course['lessons']) if l['title']==title)]
 def shown(title,k):return f'AXPopUpButton: Transcript | {k}. {steps_of(title)[k-1]}' in listing()
 def current():
  found=re.search(r'AXPopUpButton: Transcript \| (\d+)\. ',listing());return int(found.group(1)) if found else 0
 def open_paused(title):
  pointer('click',title);wait(opened(title),f'{title} did not open')
  if 'AXPopUpButton: Transcript' not in listing():pointer('click','Toggle Game Details')
  wait(lambda:'AXPopUpButton: Transcript' in listing(),f'The {title} transcript picker did not appear')
  # Opening a lesson plays it; pause first so the chosen transcript stays put.
  if 'AXButton: Pause' in listing():pointer('click','Pause')
  wait(lambda:'AXButton: Play' in listing(),f'{title} did not pause')
 # Walk with the arrows themselves: a long transcript menu runs under the Dock on a small screen.
 def last_transcript(title):
  open_paused(title);n=len(steps_of(title))
  for _ in range(n):
   k=current()
   if k==n:break
   pointer('click','Next transcript');wait(lambda:current()==k+1,f'{title}: the right arrow did not advance from transcript {k}')
  wait(lambda:shown(title,n),f'{title}: the right arrow did not reach the last transcript')
  return n
 def first_transcript(title):
  open_paused(title)
  for _ in range(len(steps_of(title))):
   k=current()
   if k==1:break
   pointer('click','Previous transcript');wait(lambda:current()==k-1,f'{title}: the left arrow did not go back from transcript {k}')
  wait(lambda:shown(title,1),f'{title}: the left arrow did not reach the first transcript')
 for lesson,following in [('The Pawn','The Rook'),('Pawn Duel','The Rook'),('The King','Safe Squares')]:
  n=last_transcript(lesson)
  pointer('click','Previous transcript');wait(lambda:shown(lesson,n-1),f'{lesson}: the left arrow did not go back')
  assert 'Next lesson' not in listing() and 'AXButton: Next transcript' in listing(),f'{lesson}: next-lesson arrow before the last transcript'
  pointer('click','Next transcript');wait(lambda:shown(lesson,n),f'{lesson}: the right arrow did not reach the last transcript')
  wait(lambda:'AXButton: Next lesson: '+following in listing(),f'{lesson}: the last transcript does not point to {following}')
  pointer('click','Next lesson: '+following);wait(opened(following),f'{lesson}: the arrow did not open {following}')
  wait(lambda:course['lessons'][[l['title'] for l in course['lessons']].index(lesson)]['id'] in saved()['course']['completed'],f'{lesson} was not marked explored')
 # The reverse: on the first transcript the left arrow opens the previous main lesson, paused at its end.
 for lesson,previous in [('The Rook','The Pawn'),('Pawn Duel','The Pawn'),('Safe Squares','The King')]:
  first_transcript(lesson)
  wait(lambda:'AXButton: Previous lesson: '+previous in listing(),f'{lesson}: the first transcript does not point back to {previous}')
  pointer('click','Next transcript');wait(lambda:shown(lesson,2),f'{lesson}: the right arrow did not advance')
  assert 'Previous lesson' not in listing() and 'AXButton: Previous transcript' in listing(),f'{lesson}: previous-lesson arrow after the first transcript'
  pointer('click','Previous transcript');wait(lambda:shown(lesson,1),f'{lesson}: the left arrow did not go back')
  pointer('click','Previous lesson: '+previous);wait(opened(previous),f'{lesson}: the arrow did not open {previous}')
  wait(lambda:shown(previous,len(steps_of(previous))) and 'AXButton: Play' in listing(),f'{lesson}: {previous} did not open paused at its end')
 pointer('scroll-sidebar','400');time.sleep(.5)
 first_transcript('Introduction')
 assert 'Previous lesson' not in listing() and 'AXButton: Previous transcript' in listing(),'The first lesson offers a previous lesson'
 pointer('scroll-sidebar','-400');time.sleep(.5)
 last_transcript('A Famous Short Game');time.sleep(.5)
 assert 'Next lesson' not in listing() and 'AXButton: Next transcript' in listing(),'The final lesson offers a next lesson'
 pointer('scroll-sidebar','400');time.sleep(.5)
 results['lessonBoundaryArrows']=True
 pointer('click','The Pawn')
 wait(lambda:'Try it against the computer' in listing(),"The Pawn lost its own practice position")
 for _ in range(3):
  pointer('click','The Rook');wait(lambda:'Practise: Rook Practice' in listing(),'The Rook row did not open its lesson')
  pointer('click','Rook Practice');wait(opened('Rook Practice'),'Rook Practice did not reopen')
 subprocess.run(['/usr/sbin/screencapture','-x',str(evidence/'practice-sub-items.png')],check=True)
 stop();value=saved();value['course']['completed']=sorted(set(value['course']['completed'])|{'pawn'});(state/'state-v1.json').write_text(json.dumps(value));launch()
 if 'AXStaticText: The Pawn' not in listing():pointer('click','Toggle Sidebar')
 wait(lambda:'AXStaticText: The Pawn' in listing(),'Sidebar did not open')
 pointer('click','The Pawn')
 if 'AXPopUpButton: Transcript' not in listing():pointer('click','Toggle Game Details')
 wait(lambda:'Continue to The Rook' in listing(),'Continue after The Pawn does not name The Rook')
 pointer('click','Continue to The Rook');wait(lambda:'Practise: Rook Practice' in listing(),'Continue did not open The Rook')
 results['practiceSubItems']=True
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
