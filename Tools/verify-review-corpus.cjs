#!/usr/bin/env node
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process'),os=require('node:os');
// The test host carries ~/.config/checkmate/host-role holding "test", the marker scripts/test_host.py reads.
const hostRole=(()=>{try{return fs.readFileSync(path.join(os.homedir(),'.config/checkmate/host-role'),'utf8').trim()}catch(error){if(error.code==='ENOENT')return null;throw error}})();
if(hostRole!=='test')throw Error('Run corpus/native verification on the test host only.');
const root=path.resolve(process.argv[2]||'../dev-docs/review-targets/20261009');
const entries=['manifest.json','manifest-expanded.json','manifest-novice.json'].flatMap(file=>JSON.parse(fs.readFileSync(path.join(root,file))).entries);
const groups=new Map();let heldOut=0;
for(const e of entries){const bytes=fs.readFileSync(path.join(root,e.path));if(crypto.createHash('sha256').update(bytes).digest('hex')!==e.sha256)throw Error('Hash mismatch: '+e.id);let parent=e.parentId||e.id,split=e.split||'tuning';if(groups.has(parent)&&groups.get(parent)!==split)throw Error('Parent leakage: '+parent);groups.set(parent,split);if(split==='held-out')heldOut++;}
if(entries.length<80||heldOut<20)throw Error('Corpus acceptance count failed.');
console.log(JSON.stringify({targets:entries.length,heldOut,parentGroups:groups.size,hashesVerified:true}));
const args=['test','--scratch-path',process.env.CHECKMATE_BUILD_PATH||'.build-review','--filter','ReviewCorpus'];
const result=cp.spawnSync('swift',args,{cwd:path.resolve(__dirname,'..'),env:{...process.env,CHECKMATE_AUTOMATION:'1',CHECKMATE_REVIEW_CORPUS:root},stdio:'inherit'});if(result.error)throw result.error;process.exit(result.status??1);
