#!/usr/bin/env python3
"""Test-host-only matched-node old/new engine packaging equivalence, no app/audio."""
import hashlib,json,os,pathlib,subprocess,sys,threading
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'scripts'))
import test_host
test_host.require('engine packaging verification')
original,replacement,gold,output=map(pathlib.Path,sys.argv[1:])
rows=json.loads(gold.read_text())
if isinstance(rows,dict):rows=rows.get('targets',rows.get('rows',[]))
rows=[row for row in rows if 'startFEN' in row]
def observe(path):
 p=subprocess.Popen([str(path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=dict(os.environ,MallocLargeCache='0'))
 def send(s):p.stdin.write(s+'\n');p.stdin.flush()
 def until(prefix,seconds=60):
  # A wedged engine must fail the check, not hang it: the watchdog kills it, so readline() returns EOF.
  expired=threading.Event()
  watchdog=threading.Timer(seconds,lambda:(expired.set(),p.kill()));watchdog.start()
  try:
   lines=[]
   while True:
    raw=p.stdout.readline()
    if not raw:
     p.wait()
     raise RuntimeError(f'Engine gave no {prefix} within {seconds}s' if expired.is_set() else 'Engine exited')
    line=raw.strip();lines.append(line)
    if line.startswith(prefix):return lines
  finally:watchdog.cancel()
 try:
  send('uci');until('uciok')
  for k,v in {'Threads':'1','Hash':'32','MultiPV':'3','Skill Level':'20','UCI_LimitStrength':'false','UCI_ShowWDL':'true'}.items():send(f'setoption name {k} value {v}')
  out=[]
  for row in rows:
   send('ucinewgame');send('isready');until('readyok')
   send('position fen '+row['startFEN']+(' moves '+' '.join(row['moves']) if row['moves'] else ''))
   send('go nodes 10000');lines=until('bestmove');snapshots={}
   for line in lines:
    f=line.split()
    if f and f[0]=='info' and 'score' in f and 'pv' in f and 'depth' in f:
     i=f.index('score');j=f.index('pv');rank=int(f[f.index('multipv')+1]) if 'multipv' in f else 1;depth=int(f[f.index('depth')+1])
     snapshots.setdefault(depth,{})[rank]={'score':f[i+1:i+3],'pv':f[j+1:]}
   complete=[d for d,ranks in snapshots.items() if len(ranks)==3]
   depth=max(complete or snapshots.keys(),default=None)
   out.append({'id':row['id'],'bestmove':lines[-1].split()[1],'depth':depth,'lines':snapshots.get(depth,{})})
  return out
 finally:
  # After a kill or an exit the pipe is gone; writing 'quit' would replace the real error with BrokenPipeError.
  # An engine that ignores quit is killed and reaped, never left running or allowed to replace the real error.
  if p.poll() is None:
   try:send('quit');p.wait(timeout=5)
   except (BrokenPipeError,subprocess.TimeoutExpired):p.kill();p.wait(timeout=5)
a=observe(original);b=observe(replacement)
results=[{'id':x['id'],'sameBestMove':x['bestmove']==y['bestmove'],'sameScoresAndPVs':x==y,'original':x,'replacement':y} for x,y in zip(a,b)]
report={'nodesPerSearch':10000,'threads':1,'hashMiB':32,'multiPV':3,'originalSHA256':hashlib.sha256(original.read_bytes()).hexdigest(),'replacementSHA256':hashlib.sha256(replacement.read_bytes()).hexdigest(),'targets':results,'passed':bool(results) and all(r['sameScoresAndPVs'] for r in results)}
output.write_text(json.dumps(report,indent=2));print(json.dumps({'passed':report['passed'],'targets':len(results),'exactMatches':sum(r['sameScoresAndPVs'] for r in results)}))
if not report['passed']:raise SystemExit(1)
