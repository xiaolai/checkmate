"""Silent test-host real-pointer checks for lesson exercises: the invitation step's own board takes the moves.

Covers, with real pointer events: castling by click and by drag with both drawers closed; an impossible castling
explained in Castling Rules; a tactic's off-track move, Take Back, the authored line, success and Play on; leaving the
exercise and coming back; promotion through the native menu; a relaunch restoring the attempt; and the practice game
staying exactly as it was throughout.
"""
import json,os,pathlib,shutil,subprocess,tempfile,time
import test_host;test_host.require('lesson exercise pointer acceptance')
root=pathlib.Path(__file__).resolve().parents[1];evidence=pathlib.Path(os.environ['CHECKMATE_EVIDENCE_DIR']);evidence.mkdir(parents=True,exist_ok=True)
helpers={}
for name in ['pointer-helper','ax-helper']:
 helpers[name]=evidence/name;subprocess.run(['xcrun','swiftc',str(root/'Tools'/f'{name}.swift'),'-o',str(helpers[name])],check=True)
state=pathlib.Path(tempfile.mkdtemp(prefix='checkmate-lesson-exercise-'));process=None
command=[str(root/'build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative'),'--automation','--data-dir',str(state)]
env={k:v for k,v in os.environ.items() if k!='CHECKMATE_AUTOMATION'}
course=json.loads((root/'Sources/CheckmateCore/Resources/course.json').read_text())
practice={l['id']:l['practice'] for l in course['lessons'] if l.get('practice')}
def pointer(*args):return subprocess.check_output([str(helpers['pointer-helper']),str(process.pid),*args],text=True).strip()
def listing():return subprocess.check_output([str(helpers['ax-helper']),str(process.pid),'list'],text=True)
def wait(test,message,timeout=25):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  try:
   if test():return
  except subprocess.CalledProcessError:pass
  time.sleep(.2)
 raise AssertionError(message)
def saved():return json.loads((state/'state-v1.json').read_text())
def label(square):return pointer('label',square)
def holds(square,piece):return lambda:label(square).startswith(f'{square}, {piece}')
def title(text):return lambda:'Current activity | '+text in listing()
def stop():
 global process
 if process:process.terminate();process.wait(timeout=10);process=None
 time.sleep(.4)
def launch():
 global process
 process=subprocess.Popen(command,env=env,stdout=subprocess.DEVNULL,stderr=(evidence/'lesson-exercise-trace.log').open('ab'))
 wait(lambda:'Chessboard' in listing(),'Board did not appear');time.sleep(1)
def drawers(sidebar,details):
 """Opens or closes each drawer with its own toolbar button and waits for it."""
 if ('AXStaticText: The Pawn' in listing())!=sidebar:pointer('click','Sidebar')
 wait(lambda:('AXStaticText: The Pawn' in listing())==sidebar,'The sidebar did not '+('open' if sidebar else 'close'))
 shown=lambda:'AXPopUpButton: Transcript' in listing() or 'practice-heading' in listing()
 if shown()!=details:pointer('click','Details')
 wait(lambda:shown()==details,'Game details did not '+('open' if details else 'close'))
def open_lesson(lesson_title):
 """Clicks a lesson in the sidebar. A row far down the list exists only once the list has scrolled near it, so the
 sidebar is scrolled down step by step (as lesson-remediation does) until the click lands."""
 for attempt in range(8):
  try:pointer('click',lesson_title);return
  except subprocess.CalledProcessError:
   if attempt==7:raise
   pointer('scroll-sidebar','-120');time.sleep(.5)
def exercise(lesson_title,lesson_id):
 """Opens a lesson from the sidebar, pauses it and goes to its exercise step through the drawer button."""
 drawers(True,True)
 open_lesson(lesson_title);wait(title(lesson_title),f'{lesson_title} did not open')
 if 'AXButton: Pause' in listing():pointer('click','Pause')
 wait(lambda:'lesson-go-to-attempt' in listing() or 'Go to Your Turn' in listing() or 'Resume Your Attempt' in listing(),f'{lesson_title} offers no way to its exercise')
 pointer('click','lesson-go-to-attempt')
 wait(title(lesson_title+' · '),f'{lesson_title}: the exercise step did not open')
 fen=practice[lesson_id]['fen'].split()[0]
 return fen
def play(move):
 pointer('click-square',move[:2]);wait(lambda:'selected' in label(move[:2]),f'{move[:2]} did not select')
 pointer('click-square',move[2:4])
def attempt(lesson_id):return saved().get('lessonAttempts',{}).get(lesson_id,{})
results={}
try:
 launch()
 # A practice game in progress before any exercise: it must be untouched at the end.
 drawers(True,True)
 pointer('click-square','e2');pointer('click-square','e4')
 wait(lambda:'1. e4 ' in saved()['practice']['pgn'] and saved()['practice']['fen'].split()[1]=='w','Computer did not reply in practice')
 # ⌘Z (Edit ▸ Undo) takes the move back, then the game goes on as before.
 pointer('shortcut','6','c');wait(lambda:'1. e4' not in saved()['practice']['pgn'],'⌘Z did not take back the practice move')
 pointer('click-square','e2');pointer('click-square','e4')
 wait(lambda:'1. e4 ' in saved()['practice']['pgn'] and saved()['practice']['fen'].split()[1]=='w','Computer did not reply in practice')
 game=saved()['practice']['pgn'];previous=saved()['practice'].get('previousGame','')

 # Castling: the playback controls stay exactly where they were from the step before the exercise to the exercise
 # step, with the drawers open and closed; then, drawers closed, a click castles; Restart, then a drag castles.
 exercise('Castling','castling')
 def slots(last):return [pointer('frame',i) for i in ['bar-stepFromStart','bar-previousStep','bar-playPause',last]]
 for sidebar,details in [(True,True),(False,False)]:
  drawers(sidebar,details);time.sleep(.6);on_exercise=slots('bar-nextLesson')
  pointer('click','bar-previousStep');wait(lambda:not title('Castling · ')(),'Castling: Previous did not leave the exercise step')
  if 'AXButton: Pause' in listing():pointer('click','bar-playPause');time.sleep(.4)
  before=slots('bar-nextStep');assert before==on_exercise,f'Castling: the playback controls moved between the steps: {before} then {on_exercise}'
  pointer('click','bar-nextStep');wait(title('Castling · '),'Castling: Next did not return to the exercise step')
 results['playbackSlotsStayPut']=True
 # In a lesson the guidance is in the details drawer, whose toggle keeps its one name (the bar has no guidance button of its own).
 assert 'Details' in listing() and 'bar-' in listing() and 'Show lesson guidance' not in listing(),'The details toggle is missing in a lesson'
 drawers(False,False)
 wait(title('Castling · Your turn'),'Castling: the title does not invite a move')
 play('e1g1')
 wait(holds('g1','White, king'),'Castling by click did not move the king');wait(holds('f1','White, rook'),'Castling by click did not move the rook')
 wait(title('Castling · Well done'),'Castling: success is not shown with the drawers closed')
 wait(lambda:attempt('castling').get('moves')==['e1g1'] and 'castling' in saved()['course'].get('practised',[]),'Castling: the attempt or achievement was not saved')
 subprocess.run(['/usr/sbin/screencapture','-x',str(evidence/'exercise-castled.png')],check=True)
 drawers(False,True);pointer('click','lesson-attempt-restart');wait(holds('e1','White, king'),'Restart did not put the king back')
 drawers(False,False);pointer('drag-square','e1','g1')
 wait(holds('g1','White, king'),'Castling by drag did not move the king');wait(holds('f1','White, rook'),'Castling by drag did not move the rook')
 results['castlingClickAndDragDrawersClosed']=True

 # Castling Rules: the impossible side is explained and nothing moves; the legal side succeeds.
 exercise('Castling Rules','castling-rules')
 mistake=practice['castling-rules']['mistakes']['e1g1']
 play('e1g1');wait(lambda:mistake in listing(),'Castling Rules: the impossible castling was not explained')
 assert label('e1').startswith('e1, White, king'),'Castling Rules: the king moved on an impossible castling'
 play('e1c1');wait(holds('c1','White, king'),'Castling Rules: queenside castling did not play');wait(holds('d1','White, rook'),'Castling Rules: the rook did not follow')
 wait(title('Castling Rules · Well done'),'Castling Rules: success not shown')
 results['impossibleCastlingExplained']=True
 # The Lesson menu by keyboard, on the same exercise: ⌘[ and ⌘] step off it and back, ⌘Z undoes its turn,
 # ⇧⌘H gives a hint, ⌘P plays and pauses the instruction.
 pointer('shortcut','33','c');wait(lambda:not title('Castling Rules · ')(),'⌘[ did not step back from the exercise')
 pointer('shortcut','30','c');wait(title('Castling Rules · '),'⌘] did not return to the exercise')
 pointer('shortcut','6','c');wait(lambda:attempt('castling-rules').get('moves')==[],'⌘Z did not undo the exercise turn')
 drawers(False,True);pointer('shortcut','4','cs');wait(lambda:'Hint 1:' in listing(),'⇧⌘H did not give a hint')
 pointer('shortcut','35','co');wait(lambda:'AXButton: Pause' in listing(),'⌥⌘P did not play the instruction')
 pointer('shortcut','35','co');wait(lambda:'AXButton: Play' in listing(),'⌥⌘P did not pause the instruction')
 results['lessonMenuShortcuts']=True

 # The Fork: an off-track move, Take Back, then the authored line to success and Play on.
 exercise('The Fork','fork')
 teaching=practice['fork']['teaching']
 off=next(m for m in ['a2a3','h2h3','b2b3','g2g3'] if m not in teaching[0]['accepted'])
 play(off);wait(title('The Fork · Try again'),'The Fork: an off-track move was not called out')
 pointer('click','Take Back');wait(title('The Fork · Your turn'),'The Fork: Take Back did not return to the learner')
 wait(lambda:attempt('fork').get('moves')==[],'The Fork: Take Back left moves behind in the saved attempt')
 node=0;played=[]
 while True:
  move=teaching[node]['accepted'][0];play(move);played.append(move)
  following=(teaching[node].get('next') or {}).get(move)
  if following is None:break
  reply=teaching[node]['replies'][move];played.append(reply)
  wait(lambda:attempt('fork').get('moves')==played,f'The Fork: the authored reply {reply} did not land')
  if node==0:
   # Leave for the explanation and come back: the attempt is exactly where it was.
   drawers(False,True);pointer('click','Previous transcript');wait(lambda:'lesson-attempt-status' not in listing(),'The previous transcript still shows the exercise')
   pointer('click','Next transcript');wait(title('The Fork · '),'The exercise step did not reopen')
   to=reply[2:4];wait(lambda:label(to).startswith(f'{to}, Black'),'The Fork: the attempt was not restored after leaving')
   results['leaveAndReturnRestores']=True
  node=following
 wait(title('The Fork · Well done'),'The Fork: the authored line did not succeed')
 drawers(False,True);pointer('click','lesson-attempt-play-on')
 wait(lambda:len(attempt('fork').get('moves',[]))==len(played)+1,'The Fork: the computer did not play on')
 wait(title('The Fork · Play on · Your turn'),'The Fork: play on did not return the move to the learner')
 results['tacticOffTrackUndoLineAndPlayOn']=True

 # Promotion and En Passant: capture en passant, then promote through the native menu.
 exercise('Promotion and En Passant','promotion-en-passant')
 play('e5d6');wait(holds('d6','White, pawn'),'En passant did not play');wait(lambda:not label('d5').startswith('d5, Black'),'En passant did not remove the passed pawn')
 wait(lambda:len(attempt('promotion-en-passant').get('moves',[]))==2,'The computer did not answer the en passant capture')
 play('a6a7');wait(lambda:len(attempt('promotion-en-passant').get('moves',[]))==4,'The computer did not answer a6-a7')
 pointer('click-square','a7');pointer('click-square','a8')
 wait(lambda:pointer('menu-open','Knight')=='true','The promotion menu did not open in the exercise')
 pointer('choose-menu-item','Knight');wait(holds('a8','White, knight'),'The menu choice did not promote to a knight')
 wait(title('Promotion and En Passant · Well done'),'Promotion and En Passant: success not shown')
 results['promotionMenuInExercise']=True

 # A relaunch keeps every attempt. The Fork reopens at its reading position, the exercise step, exactly where it was;
 # from its first step the drawer offers to resume the attempt.
 moves=attempt('fork')['moves'];stop();launch();drawers(True,True)
 open_lesson('The Fork');wait(title('The Fork · Play on · Your turn'),'The Fork: the exercise did not reopen where it was after relaunch')
 last=moves[-1][2:4];wait(lambda:label(last).startswith(f'{last}, Black'),'The Fork: the restored board does not show the last move')
 pointer('click','Previous transcript');wait(lambda:'Resume Your Attempt' in listing(),'The Fork: the saved attempt is not offered from the explanation')
 pointer('click','lesson-go-to-attempt');wait(title('The Fork · Play on · Your turn'),'The Fork: Resume your attempt did not reopen it')
 assert attempt('fork')['moves']==moves,'The Fork: the relaunched attempt changed'
 results['relaunchRestoresAttempt']=True

 assert saved()['practice']['pgn']==game and saved()['practice'].get('previousGame','')==previous,'An exercise touched the practice game'
 results['practiceGameUntouched']=True
 results['silent']=True
 results['passed']=True
 (evidence/'lesson-exercise-results.json').write_text(json.dumps(results,indent=2))
 print(json.dumps(results))
except Exception:
 (evidence/'lesson-exercise-failure-ax.txt').write_text(listing() if process else '')
 subprocess.run(['/usr/sbin/screencapture','-x',str(evidence/'lesson-exercise-failure.png')],check=True)
 raise
finally:
 stop()
 shutil.rmtree(state,ignore_errors=True)
