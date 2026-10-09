import hashlib,json,pathlib,re,sys
p=pathlib.Path(sys.argv[1])
log=(p/'swift-tests.log').read_text()
assert "Test Suite 'All tests' passed" in log
count=int(re.findall(r'Executed (\d+) tests, with 0 failures',log)[-1])
assert "skipped" not in log.lower()
r={'deterministicTests':count,'liveVoice':'deferred-user-owned'}
for key,file in [('layout','layout-verification.json'),('lifecycle','lifecycle-results.json'),('fullscreen','fullscreen-results.json'),('nativeUI','ui-results.json'),('brokerIntegration','broker-results.json'),('relocatedLaunch','relocated-results.json'),('packaging','package-results.json')]:
 r[key]=json.loads((p/file).read_text())['passed']
 assert r[key],file
files=[pathlib.Path('Package.swift'),pathlib.Path('build.sh')]
files += [f for folder in ['Sources/CheckmateCore','Sources/CheckmateNative','Tests','scripts','Tools','Artwork'] for f in pathlib.Path(folder).rglob('*') if f.is_file() and 'Resources/course/' not in str(f)]
r['sourceHashes']={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(files)}
(p/'acceptance.json').write_text(json.dumps(r,indent=2))
print(json.dumps({k:v for k,v in r.items() if k!='sourceHashes'}))
