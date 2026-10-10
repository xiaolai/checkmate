import hashlib,json,pathlib,re,sys
p=pathlib.Path(sys.argv[1])
log=(p/'swift-tests.log').read_text()
assert "Test Suite 'All tests' passed" in log
summary=re.findall(r'Executed (\d+) tests, with (?:(\d+) tests skipped and )?0 failures',log)
assert summary, "No successful XCTest summary"
count,skipped=summary[-1]
count,skipped=int(count),int(skipped or 0)
optional={
 'EngineGoldenTests testHeldOutStrongEvidence',
 'OpponentCalibrationTests testSeededCompleteGames',
 'ReviewPerformanceTests testImportNavigationAndSelectedLatency',
 'ReviewPerformanceTests testMaximumMainlineNavigationScale',
 'ReviewPerformanceTests testSelectedQuickP95OnActualGame',
}
skipped_names=re.findall(r"Test Case '-\[CheckmateCoreTests\.(.*?)\]' skipped",log)
assert len(skipped_names)==skipped, "Unaccounted skipped tests"
assert set(skipped_names)<=optional, f"Unexpected skipped tests: {set(skipped_names)-optional}"
r={'deterministicTests':count-skipped,'totalTests':count,'optionalSkippedTests':skipped_names,'liveVoice':'deferred-user-owned'}
for key,file in [('layout','layout-verification.json'),('lifecycle','lifecycle-results.json'),('fullscreen','fullscreen-results.json'),('nativeUI','ui-results.json'),('brokerIntegration','broker-results.json'),('relocatedLaunch','relocated-results.json'),('packaging','package-results.json')]:
 r[key]=json.loads((p/file).read_text())['passed']
 assert r[key],file
files=[pathlib.Path('Package.swift'),pathlib.Path('build.sh')]
files += [f for folder in ['Sources/CheckmateCore','Sources/CheckmateNative','Tests','scripts','Tools','Artwork'] for f in pathlib.Path(folder).rglob('*') if f.is_file() and 'Resources/course/' not in str(f)]
r['sourceHashes']={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(files)}
(p/'acceptance.json').write_text(json.dumps(r,indent=2))
print(json.dumps({k:v for k,v in r.items() if k!='sourceHashes'}))
