import json,pathlib,subprocess,sys
from gate_check import check_gate,check_unit
p=pathlib.Path(sys.argv[1])
gates=json.loads((pathlib.Path(__file__).parent/'gates.json').read_text())['gates']
r={**check_unit(p),'liveVoice':'deferred-user-owned'}
# Every gate must pass in full (gate_check): a false flag or a skipped/failed sub-result fails the run.
for gate in gates:
 check_gate(p,gate)
 if gate['name']!='unit':r[gate['key']]=True
# The run certifies only the tree it started with: a source edited mid-run fails the run.
start=json.loads((p/'source-hashes-start.json').read_text())
end=json.loads(subprocess.check_output([sys.executable,'scripts/source-hashes.py','.'],text=True))
changed=sorted(k for k in start.keys()|end.keys() if start.get(k)!=end.get(k))
assert not changed,f'Sources changed during the acceptance run: {changed[:20]}'
r['sourceHashes']=start
(p/'acceptance.json').write_text(json.dumps(r,indent=2))
print(json.dumps({k:v for k,v in r.items() if k!='sourceHashes'}))
