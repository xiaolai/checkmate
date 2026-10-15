#!/usr/bin/env python3
"""Align authored anchor phrases to Cedar masters on the build host. Never plays audio.

A phrase list times a beat's moves, or, on a staged beat, the stages after the first. Uses whisper-1 word timestamps;
raw results are cached by audio hash, so re-aligning changed phrases on cached recordings makes no request. No
credentials, response bodies or request headers are printed. Fail closed when an authored phrase cannot be aligned,
matches two places equally well, or lands on a timestamp outside its recording. Dry run by default; --generate is paid
for recordings not yet transcribed.
"""
import argparse
import difflib
import importlib.util
import json
import re
import sys
import threading
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import test_host
spec=importlib.util.spec_from_file_location('recorder',ROOT/'Tools/record-lessons.py')
recorder=importlib.util.module_from_spec(spec);spec.loader.exec_module(recorder)
spec=importlib.util.spec_from_file_location('prepare',ROOT/'Tools/prepare-lesson-scripts.py')
prepare=importlib.util.module_from_spec(spec);spec.loader.exec_module(prepare)
# Whisper word timestamps can run a little past the end of a trimmed recording; anything further is malformed.
TIMESTAMP_SLACK=0.25
NUMBERS=dict(zip('12345678','one two three four'.split()+'five six seven eight'.split()))
def tokens(text):
    text=re.sub(r'\b([a-h])([1-8])\b',lambda m:m[1]+' '+NUMBERS[m[2]],text.lower())
    text=re.sub(r'\b([1-8])\b',lambda m:NUMBERS[m[1]],text)
    return re.findall(r'[a-z]+',text)
def align(words,phrases,seconds):
    expanded=[]
    for w in words:
        if not isinstance(w.get('start'),(int,float)) or not 0<=w['start']<=seconds+TIMESTAMP_SLACK:raise ValueError('A word timestamp lies outside its recording')
        expanded.extend((token,w['start']) for token in tokens(w['word']))
    stream=[t for t,_ in expanded];cursor=0;fractions=[]
    for phrase in phrases:
        wanted=tokens(phrase);best=None;scores=[]
        for start in range(cursor,len(stream)):
            for length in range(max(1,len(wanted)-2),len(wanted)+3):
                score=difflib.SequenceMatcher(None,wanted,stream[start:start+length]).ratio()
                scores.append((score,start,length))
                if best is None or score>best[0]:best=(score,start,length)
        if best is None or best[0]<0.88:raise ValueError('An authored action phrase was not recognised confidently')
        _,start,length=best
        # A phrase that fits a second, separate place as well as the first could time the wrong sentence.
        if any(score>=best[0] and (other+size<=start or other>=start+length) for score,other,size in scores):raise ValueError('An authored action phrase matches two places')
        # Begin when the named piece is introduced; the move continues while its destination is spoken.
        fractions.append(round(max(0,min(1,expanded[start][1]/seconds)),6));cursor=start+length
    if fractions!=sorted(fractions):raise ValueError('Movement cues are out of order')
    return fractions

def transcribe(file,script,key):
    boundary='checkmate-'+uuid.uuid4().hex;parts=[]
    def field(name,value):parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    for name,value in [('model','whisper-1'),('language','en'),('response_format','verbose_json'),('timestamp_granularities[]','word'),('prompt',script)]:field(name,value)
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="lesson.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode()+file.read_bytes()+b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    request=urllib.request.Request('https://api.openai.com/v1/audio/transcriptions',data=b''.join(parts),headers={'Authorization':'Bearer '+key,'Content-Type':'multipart/form-data; boundary='+boundary})
    try:
        with urllib.request.build_opener(recorder.NoRedirect).open(request,timeout=180) as response:return json.load(response)
    except Exception:raise ValueError('Word-timestamp request failed; no response body logged') from None

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--generate',action='store_true');parser.add_argument('--api-key-stdin',action='store_true');parser.add_argument('--recordings',type=Path,default=ROOT/'recordings/cedar');args=parser.parse_args()
    test_host.require('lesson action alignment',role='build')
    phrases=json.loads((ROOT/'Content/lesson-action-phrases.json').read_text())['phrases']
    units={u['id']:u for u in recorder.load_units(ROOT/'Content/lesson-narration.en-GB.jsonl')}
    print(json.dumps({'clips':len(phrases),'mode':'generate' if args.generate else 'dry_run'}),flush=True)
    if not args.generate:return
    cache=ROOT/'recordings/action-alignment';cache.mkdir(parents=True,exist_ok=True);key=None;lock=threading.Lock()
    # The credential is read once, and only when a recording has no cached transcript.
    def credential():
        nonlocal key
        with lock:
            if key is None:key=sys.stdin.read().strip() if args.api_key_stdin else recorder.api_key()
            return key
    def job(identity):
        unit=units[identity];body=recorder.payload(json.loads((ROOT/'Content/narration-profile.cedar.json').read_text()),unit['text'])
        identity_hash=recorder.request_hash(body);stem=args.recordings/unit['lessonId']/(f"{unit['beatIndex']:02d}-{identity_hash}");metadata=json.loads(stem.with_suffix('.json').read_text());audio=stem.with_suffix('.wav')
        if metadata['requestSHA256']!=recorder.request_hash(body) or metadata['audioSHA256']!=recorder.digest(audio.read_bytes()):raise ValueError('Stale master '+identity)
        file=cache/(metadata['audioSHA256']+'.json')
        if file.exists():result=json.loads(file.read_text())
        else:result=transcribe(audio,unit['text'],credential());recorder.atomic_write(file,json.dumps(result).encode())
        try:fractions=align(result['words'],phrases[identity],metadata['audio']['seconds'])
        except ValueError as error:raise ValueError(identity+': '+str(error)) from None
        print(identity+': aligned '+str(len(fractions))+' anchors',flush=True)
        return identity,{'textSHA256':unit['sha256'],'masterSHA256':metadata['audioSHA256'],'anchorsSHA256':prepare.anchor_identity(phrases[identity]),'fractions':fractions,'method':'whisper-1-authored-phrase'}
    with ThreadPoolExecutor(max_workers=4) as executor:cues=dict(executor.map(job,phrases))
    recorder.atomic_write(ROOT/'Content/lesson-action-cues.json',(json.dumps({'schemaVersion':1,'cues':cues},indent=2)+'\n').encode())
if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,OSError) as error:raise SystemExit(str(error)) from None
