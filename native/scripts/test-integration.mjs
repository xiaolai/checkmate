import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {BrokerClient} from '../../packages/companion-mcp/dist/packages/companion-mcp/src/broker.js';
const path=process.argv[2];
const client=new BrokerClient(path);
try{
 if(process.argv[3]==='preview') {let s;for(let i=0;i<40;i++){s=await client.call('get_session',{});if(s.preview?.status==='ready')break;await new Promise(r=>setTimeout(r,100))};assert.equal(s.preview?.status,'ready');const response=await client.call('show_preview',{sessionId:s.sessionId,revision:s.revision,positionId:s.positionId,previewId:s.preview.id,requestId:'seek-preview',line:'candidate',ply:1});assert.equal(response.hypothetical,true);console.log(JSON.stringify({passed:true,checks:1,tools:['show_preview']}));}
 else if(process.argv[3]==='opponent'){const s=await client.call('get_session',{});const move=await client.call('play_move',{sessionId:s.sessionId,revision:s.revision,requestId:'black-reply'});assert.ok(move.uci,JSON.stringify(move));assert.equal(move.state.state.turn,'w');console.log(JSON.stringify({passed:true,checks:1,tools:['play_move']}));}
 else {
 const state=await client.call('get_session',{});assert.ok(state.sessionId,JSON.stringify(state));assert.equal(state.mode,'practice');
 const at={sessionId:state.sessionId,revision:state.revision};
 const legal=await client.call('get_legal_moves',at);assert.equal(legal.moves.length,20);
 const facts=await client.call('get_turn_brief',{});assert.equal(facts.state.positionId,state.positionId);
 const inspect=await client.call('inspect_piece',{...at,square:'g1',target:'display'});assert.ok(inspect.inspection.destinations.includes('f3'));
 const annotation={...at,positionId:state.positionId,displayIdentity:state.display.identity,requestId:'native-integration',highlights:[{sq:'e2',kind:'focus'}],arrows:[['e2','e4']],ttlMs:1000};
 const first=await client.call('show_annotation',annotation),second=await client.call('show_annotation',annotation);assert.equal(second.overlayRevision,first.overlayRevision);
 const stale=await client.call('get_legal_moves',{...at,revision:999});assert.equal(stale.error.code,'STALE_STATE');
 const forbidden=await client.call('play_move',{...at,requestId:'forbidden'});assert.equal(forbidden.error.code,'ROLE_FORBIDDEN');
 const bad=await client.call('get_session',{unknown:true});assert.equal(bad.error.code,'INVALID_ARGUMENT');
 const competitor=new BrokerClient(path);assert.equal((await competitor.call('get_session',{})).error.code,'SESSION_IN_USE');await competitor.close();
 const controller=new AbortController();const waiting=client.call('wait_for_change',{sessionId:state.sessionId,cursor:state.cursor,timeoutMs:20000},controller.signal);setTimeout(()=>controller.abort(),100);assert.equal((await waiting).error.code,'CANCELLED');
 const discovery=JSON.parse(await readFile(path,'utf8'));const origin=await fetch(discovery.url+'/rpc',{method:'POST',headers:{authorization:'Bearer '+discovery.token,'x-checkmate-client':crypto.randomUUID(),origin:'https://example.com'},body:'{}'});assert.equal((await origin.json()).error.code,'NOT_AUTHORIZED');
 const analysis=await client.call('analyze_position',{...at,movetimeMs:100});assert.ok(analysis.analysis?.bestMove,JSON.stringify(analysis));
 const candidate=await client.call('preview_move',{...at,from:'e2',to:'e4'});assert.ok(candidate.candidate,JSON.stringify(candidate));assert.equal(candidate.candidate.to,'e4');assert.equal((await client.call('get_session',{})).state.fen,state.state.fen);
 const clear=await client.call('clear_annotations',{...at,positionId:state.positionId,requestId:'clear'});assert.ok(clear.overlayRevision);
 const demo=await client.call('demonstrate_line',{...at,positionId:state.positionId,requestId:'demo',title:'Opening',lines:[{label:'Center',moves:[{uci:'e2e4'},{uci:'e7e5'}]}]});assert.ok(demo.demonstration?.id,JSON.stringify(demo));
 const current=await client.call('get_session',{});const seek=await client.call('control_demonstration',{sessionId:current.sessionId,revision:current.revision,positionId:current.positionId,requestId:'seek-demo',demonstrationId:demo.demonstration.id,action:'seek',line:0,ply:2});assert.equal(seek.demonstration.ply,2);assert.equal((await client.call('get_session',{})).state.fen,state.state.fen);
 console.log(JSON.stringify({passed:true,checks:16,tools:['get_session','get_legal_moves','get_turn_brief','inspect_piece','show_annotation','play_move','wait_for_change','analyze_position','preview_move','clear_annotations','demonstrate_line','control_demonstration']}));
 }
}finally{await client.close()}
