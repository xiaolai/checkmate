#!/usr/bin/env python3
"""Exercise the shipped native MCP executable over its actual stdio protocol."""
import json,os,pathlib,selectors,subprocess,sys,time,uuid,urllib.request

class Client:
    def __init__(self, executable, discovery):
        execution_arch=os.environ.get('CHECKMATE_EXECUTION_ARCH')
        assert execution_arch in (None,'arm64','x86_64'), 'Invalid execution architecture'
        launcher=['/usr/bin/arch','-'+execution_arch] if execution_arch else []
        self.process=subprocess.Popen(launcher+[str(pathlib.Path(executable).resolve()),'--connection-file',str(pathlib.Path(discovery).resolve())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd='/tmp',env=dict(os.environ,PATH='/usr/bin:/bin:/usr/sbin:/sbin'))
        self.sequence=0
        self.selector=selectors.DefaultSelector();self.selector.register(self.process.stdout,selectors.EVENT_READ)
        self.buffer=b'';self.pending={}
        self.request('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'native-acceptance','version':'1'}})
        self.send({'jsonrpc':'2.0','method':'notifications/initialized'})
    def send(self,value):
        self.process.stdin.write((json.dumps(value)+'\n').encode());self.process.stdin.flush()
    def begin(self,method,params):
        self.sequence+=1;self.send({'jsonrpc':'2.0','id':self.sequence,'method':method,'params':params});return self.sequence
    def receive(self,identifier):
        deadline=time.monotonic()+35
        while identifier not in self.pending:
            if b'\n' in self.buffer:
                line,self.buffer=self.buffer.split(b'\n',1)
                if line:
                    value=json.loads(line)
                    if 'id' in value:self.pending[value['id']]=value
                continue
            assert self.selector.select(max(0,deadline-time.monotonic())), 'MCP response timed out'
            data=os.read(self.process.stdout.fileno(),131072)
            assert data,'MCP exited before responding'
            self.buffer+=data
        value=self.pending.pop(identifier)
        assert 'error' not in value,value
        return value['result']
    def request(self,method,params):return self.receive(self.begin(method,params))
    def call(self,name,args):
        result=self.request('tools/call',{'name':name,'arguments':args})
        assert result['structuredContent']==json.loads(result['content'][0]['text'])
        return result['structuredContent']
    def close(self):
        self.process.stdin.close()
        try:self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill();self.process.wait();raise AssertionError('Native MCP did not exit on stdin EOF')
        assert self.process.returncode==0,self.process.stderr.read().decode()
        self.selector.close()

def main():
    executable,discovery=sys.argv[1:3];phase=sys.argv[3] if len(sys.argv)>3 else 'coach';client=Client(executable,discovery)
    try:
        definitions=client.request('tools/list',{})['tools'];assert len(definitions)==23
        assert {t['name'] for t in definitions}==set(json.loads((pathlib.Path(__file__).resolve().parents[1]/'Sources/CheckmateCore/Resources/tool-schemas.json').read_text()))
        if phase=='preview':
            for _ in range(40):
                s=client.call('get_session',{})
                if s.get('preview',{}).get('status')=='ready':break
                time.sleep(.1)
            response=client.call('show_preview',dict(sessionId=s['sessionId'],revision=s['revision'],positionId=s['positionId'],previewId=s['preview']['id'],requestId='seek-preview',line='candidate',ply=1));assert response['hypothetical']
            print(json.dumps({'passed':True,'checks':1,'tools':['show_preview']}));return
        if phase=='opponent':
            s=client.call('get_session',{});move=client.call('play_move',dict(sessionId=s['sessionId'],revision=s['revision'],requestId='black-reply'));assert move.get('uci'),move;assert move['state']['state']['turn']=='w'
            print(json.dumps({'passed':True,'checks':1,'tools':['play_move']}));return
        state=client.call('get_session',{});assert state['mode']=='practice',state
        at=dict(sessionId=state['sessionId'],revision=state['revision'])
        assert len(client.call('get_legal_moves',at)['moves'])==20
        assert client.call('get_turn_brief',{})['state']['positionId']==state['positionId']
        assert 'f3' in client.call('inspect_piece',dict(at,square='g1',target='display'))['inspection']['destinations']
        annotation=dict(at,positionId=state['positionId'],displayIdentity=state['display']['identity'],requestId='native-integration',highlights=[{'sq':'e2','kind':'focus'}],arrows=[['e2','e4']],ttlMs=1000)
        first=client.call('show_annotation',annotation);second=client.call('show_annotation',annotation);assert first['overlayRevision']==second['overlayRevision']
        assert client.call('get_legal_moves',dict(at,revision=999))['error']['code']=='STALE_STATE'
        assert client.call('play_move',dict(at,requestId='forbidden'))['error']['code']=='ROLE_FORBIDDEN'
        assert client.call('get_session',{'unknown':True})['error']['code']=='INVALID_ARGUMENT'
        competitor=Client(executable,discovery)
        try:assert competitor.call('get_session',{})['error']['code']=='SESSION_IN_USE'
        finally:competitor.close()
        waiting=client.begin('tools/call',{'name':'wait_for_change','arguments':dict(sessionId=state['sessionId'],cursor=state['cursor'],timeoutMs=20000)})
        time.sleep(.1);client.send({'jsonrpc':'2.0','method':'notifications/cancelled','params':{'requestId':waiting,'reason':'acceptance'}})
        # MCP cancellation may omit its response; a fresh request must still complete.
        assert client.call('get_session',{})['sessionId']==state['sessionId']
        d=json.loads(pathlib.Path(discovery).read_text());req=urllib.request.Request(d['url']+'/rpc',data=b'{}',headers={'Authorization':'Bearer '+d['token'],'x-checkmate-client':str(uuid.uuid4()),'Origin':'https://example.com'},method='POST')
        try:response=urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:response=error
        assert json.load(response)['error']['code']=='NOT_AUTHORIZED'
        assert client.call('analyze_position',dict(at,movetimeMs=100))['analysis']['bestMove']
        candidate=client.call('preview_move',dict(at,**{'from':'e2','to':'e4'}));assert candidate['candidate']['to']=='e4';assert client.call('get_session',{})['state']['fen']==state['state']['fen']
        assert client.call('clear_annotations',dict(at,positionId=state['positionId'],requestId='clear'))['overlayRevision']
        demo=client.call('demonstrate_line',dict(at,positionId=state['positionId'],requestId='demo',title='Opening',lines=[{'label':'Center','moves':[{'uci':'e2e4'},{'uci':'e7e5'}]}]));assert demo['demonstration']['id']
        current=client.call('get_session',{});seek=client.call('control_demonstration',dict(sessionId=current['sessionId'],revision=current['revision'],positionId=current['positionId'],requestId='seek-demo',demonstrationId=demo['demonstration']['id'],action='seek',line=0,ply=2));assert seek['demonstration']['ply']==2
        assert client.call('get_session',{})['state']['fen']==state['state']['fen']
        # An idle MCP retains its lease via native heartbeats, then EOF releases it.
        time.sleep(11);assert client.call('get_session',{})['sessionId']==state['sessionId']
        print(json.dumps({'passed':True,'checks':17,'tools':['get_session','get_legal_moves','get_turn_brief','inspect_piece','show_annotation','play_move','wait_for_change','analyze_position','preview_move','clear_annotations','demonstrate_line','control_demonstration']}))
    finally:client.close()
    reopened=Client(executable,discovery)
    try:assert reopened.call('get_session',{}).get('sessionId')
    finally:reopened.close()
if __name__=='__main__':main()
