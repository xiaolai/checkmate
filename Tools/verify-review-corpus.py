#!/usr/bin/env python3
"""Verify the review corpus offline on the test host: every target's hash, no parent split across tuning and held-out,
at least 80 targets with 20 held out, then the native ReviewCorpus tests against the same corpus.

Usage: python3 Tools/verify-review-corpus.py [corpus]  (default Tests/Fixtures/GameReview, as the tests use)
"""
import hashlib, json, os, pathlib, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'scripts'))
import test_host
test_host.require('corpus/native verification')
corpus=pathlib.Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'Tests/Fixtures/GameReview'
entries=[e for file in ['manifest.json','manifest-expanded.json','manifest-novice.json'] for e in json.loads((corpus/file).read_text())['entries']]
groups={};held_out=0
for e in entries:
    if hashlib.sha256((corpus/e['path']).read_bytes()).hexdigest()!=e['sha256']:raise SystemExit('Hash mismatch: '+e['id'])
    parent,split=e.get('parentId') or e['id'],e.get('split') or 'tuning'
    if groups.setdefault(parent,split)!=split:raise SystemExit('Parent leakage: '+parent)
    if split=='held-out':held_out+=1
if len(entries)<80 or held_out<20:raise SystemExit('Corpus acceptance count failed.')
print(json.dumps({'targets':len(entries),'heldOut':held_out,'parentGroups':len(groups),'hashesVerified':True},separators=(',',':')),flush=True)
scratch=os.environ.get('CHECKMATE_BUILD_PATH') or '.build-review'
arguments=[sys.executable,'scripts/fresh-sources.py',scratch,'--','swift','test','--scratch-path',scratch,'--filter','ReviewCorpus']
sys.exit(subprocess.run(arguments,cwd=root,env={**os.environ,'CHECKMATE_AUTOMATION':'1','CHECKMATE_REVIEW_CORPUS':str(corpus)}).returncode)
