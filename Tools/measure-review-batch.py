#!/usr/bin/env python3
"""Silent test-host-only actual app+descendant-engine batch/RSS acceptance probe."""
import hashlib, json, os, pathlib, subprocess, sys, tempfile, time
root=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'scripts'))
import test_host
test_host.require('native performance probes')
destination=pathlib.Path(sys.argv[1]).resolve();destination.mkdir(parents=True,exist_ok=True)
(destination/'input.pgn').write_bytes((root/'Tests/Fixtures/GameReview/games/public-07.pgn').read_bytes())
warm='--warm' in sys.argv[2:]
for name in ('batch-results.json','rss-results.json','baseline-ready'):
    (destination/name).unlink(missing_ok=True)
environment=dict(os.environ,CHECKMATE_AUTOMATION='1')
state=tempfile.mkdtemp(prefix='checkmate-batch-state-')
with (destination/'app.log').open('w') as log:
    app=subprocess.Popen([str(root/'build/CheckmateReviewAutomation.app/Contents/MacOS/CheckmateNative'),'--automation','--data-dir',state,'--review-batch-scenario',str(destination)]+(['--warm-engine-baseline'] if warm else []),env=environment,stdout=log,stderr=subprocess.STDOUT)
    samples=[];start=time.monotonic();baseline_ready=None
    try:
        while app.poll() is None and time.monotonic()-start<200:
            if baseline_ready is None and (destination/'baseline-ready').exists():baseline_ready=time.monotonic()-start
            raw=subprocess.check_output(['ps','-axo','pid=,ppid=,rss='],text=True)
            processes={int(row[0]):(int(row[1]),int(row[2])) for line in raw.splitlines() if len(row:=line.split())==3}
            owned={app.pid}
            while True:
                expanded=owned|{pid for pid,(parent,rss) in processes.items() if parent in owned}
                if expanded==owned:break
                owned=expanded
            samples.append({'seconds':time.monotonic()-start,'rssKiB':sum(processes.get(pid,(0,0))[1] for pid in owned),'processes':len(owned),'rssByPid':{str(pid):processes.get(pid,(0,0))[1] for pid in owned}})
            time.sleep(.1)
        if app.poll() is None:raise RuntimeError('Actual app batch exceeded200second harness deadline.')
    finally:
        if app.poll() is None:app.terminate();app.wait(timeout=5)
if baseline_ready is None:raise RuntimeError('App never reached baseline marker.')
baseline=max(sample['rssKiB'] for sample in samples if baseline_ready+.2<=sample['seconds']<=baseline_ready+1.2)
peak=max(sample['rssKiB'] for sample in samples)
result={'binaryHash':hashlib.sha256((root/'build/CheckmateReviewAutomation.app/Contents/MacOS/CheckmateNative').read_bytes()).hexdigest(),'baselineKiB':baseline,'peakKiB':peak,'incrementalMiB':(peak-baseline)/1024,'targetIncrementalMiB':256,'warmEngineBaseline':warm,'passed':(peak-baseline)<=256*1024,'method':'External ps RSS sum of isolated actual app and all descendant processes; baseline0.2-1.2sec after explicit readiness marker before2sec delayed import; optionalwarm flag performs one100ms engine search beforemarker,100ply actual public game cold batch; concurrent separate calibration excluded','samples':samples}
(destination/'rss-results.json').write_text(json.dumps(result,indent=2))
batch=json.loads((destination/'batch-results.json').read_text());print(json.dumps({'batch':batch,'rss':{key:value for key,value in result.items() if key!='samples'}}))
if not result['passed'] or not batch['passed']:raise SystemExit(1)
