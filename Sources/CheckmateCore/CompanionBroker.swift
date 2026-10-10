import Foundation
import Network
import Security
import Combine
@MainActor public final class CompanionBroker:ObservableObject {
    public let session:GameSession,tools:CompanionTools,directory:URL
    @Published public private(set) var enabled=false
    @Published public private(set) var connected=false
    @Published public private(set) var status="Disconnected"
    @Published public private(set) var error:String?
    private var listener:NWListener?,authorizationNonce="",port:UInt16=0,owner:String?,lease:String?,touched=Date(),heartbeat:Timer?
    private let leaseTimeout:TimeInterval,heartbeatInterval:TimeInterval,requestTimeout:TimeInterval
    private var generation=UUID()
    public var connectionGeneration:UUID{generation}
    private var reservesSession=false,configuredRole="coach"
    private var observation:AnyCancellable?
    private var connectionRequests:[ObjectIdentifier:String]=[:],requestOwners:[String:ObjectIdentifier]=[:]
    private var deadlines:[String:Task<Void,Never>]=[:]
    private var pending:[String:Task<Void,Never>]=[:],connections:[UUID:NWConnection]=[:]
    public init(session:GameSession,directory:URL,leaseTimeout:TimeInterval=35,heartbeatInterval:TimeInterval=1,requestTimeout:TimeInterval=25) throws {self.requestTimeout=requestTimeout;self.leaseTimeout=leaseTimeout;self.heartbeatInterval=heartbeatInterval;self.session=session;self.directory=directory;tools=try CompanionTools(session:session);observation=session.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.updateWaitingStatus()}}}
    public var activeRequestCount:Int{pending.count}
    public var activeConnectionCount:Int{connections.count}
    public func enable(role:String,standby:Bool=false) throws {
        do {
        NativeLog.companion.debug("Starting private loopback broker");disable();error=nil;let epoch=UUID();generation=epoch;guard standby || session.voiceLease==nil else{throw ProtocolFailure("SESSION_IN_USE")};configuredRole=role;reservesSession = !standby
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener=try NWListener(using:parameters,on:.any);self.listener=listener
        var bytes=[UInt8](repeating:0,count:32);guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else{throw ProtocolFailure("INTERNAL_ERROR")};authorizationNonce=bytes.map{String(format:"%02x",$0)}.joined()
        enabled=true;status="Starting companion…";if reservesSession{session.setConnection(enabled:true,role:role)}
        listener.stateUpdateHandler={[weak self] state in Task{@MainActor in guard let self=self,self.generation==epoch else{return};switch state {case .ready:guard let port=listener.port else{return};self.port=port.rawValue;do{try self.writeDiscovery();self.updateWaitingStatus()}catch{self.error="Could not publish the private connection file.";self.disable()};case .failed:self.error="The companion could not open a local connection.";self.disable();default:break}}}
        listener.newConnectionHandler={[weak self] connection in Task{@MainActor in guard let self=self,self.generation==epoch else{connection.cancel();return};self.accept(connection)}};listener.start(queue:.main)
        heartbeat=Timer.scheduledTimer(withTimeInterval:heartbeatInterval,repeats:true){[weak self] _ in Task{@MainActor in guard let self=self,self.owner != nil,Date().timeIntervalSince(self.touched)>self.leaseTimeout else{return};self.release()}}
        } catch {
            disable();self.error="The companion could not start. Check local connectivity and try enabling MCP again."
            throw error
        }
    }
    public func disable(){NativeLog.companion.debug("Disabling broker and cancelling pending requests");generation=UUID();enabled=false;heartbeat?.invalidate();heartbeat=nil;listener?.stateUpdateHandler=nil;listener?.newConnectionHandler=nil;listener?.cancel();listener=nil;release();for c in connections.values{c.cancel()};connections.removeAll();try? FileManager.default.removeItem(at:directory.appendingPathComponent("connection.json"));authorizationNonce="";port=0;session.setConnection(enabled:false,role:session.companionRole);status="Disconnected"}
    public func release(){for deadline in deadlines.values{deadline.cancel()};deadlines.removeAll();for task in pending.values{task.cancel()};pending.removeAll();requestOwners.removeAll();tools.reset();owner=nil;lease=nil;connected=false;if session.companionEnabled || session.companionLease != nil || reservesSession{session.setConnection(enabled:enabled && reservesSession,role:configuredRole)};updateWaitingStatus()}
    public func suspend(_ value:Bool){guard enabled else{return};session.setConnection(enabled:enabled && (reservesSession || connected),role:configuredRole,lease:lease,suspended:value);status=value ? "Suspended — show Checkmate to continue":connected ? "Connected":"Waiting for a Codex connection"}
    private func updateWaitingStatus(){
        guard enabled,!connected,port>0,!session.suspended else{return}
        status=session.voiceLease==nil ? "Waiting for a Codex connection":"MCP ready — disconnect voice to connect Codex"
    }
    private func writeDiscovery() throws {
        let fm=FileManager.default
        if fm.fileExists(atPath:directory.path){let attrs=try fm.attributesOfItem(atPath:directory.path);guard attrs[.type] as? FileAttributeType == .typeDirectory else{throw ProtocolFailure("NOT_AUTHORIZED")}}
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let data=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"url":"http://127.0.0.1:\(port)","token":authorizationNonce]);let url=directory.appendingPathComponent("connection.json");try data.write(to:url,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func accept(_ c:NWConnection){guard enabled,connections.count<16 else{c.cancel();return};let id=UUID(),key=ObjectIdentifier(c);connections[id]=c;let timeout=DispatchWorkItem{[weak c] in c?.cancel()};DispatchQueue.main.asyncAfter(deadline:.now()+5,execute:timeout)
        c.stateUpdateHandler={[weak self] state in switch state{case .cancelled,.failed:Task{@MainActor in guard let self=self else{return};self.connections[id]=nil;self.cancelConnectionRequest(key)};default:break}}

        c.start(queue:.main);receive(c,id:id,data:Data(),timeout:timeout)
    }
    private func cancelConnectionRequest(_ key:ObjectIdentifier){if let request=connectionRequests.removeValue(forKey:key),requestOwners[request]==key{pending[request]?.cancel()}}
    private func observeDisconnect(_ c:NWConnection){c.receive(minimumIncompleteLength:1,maximumLength:1){[weak self] data,_,complete,error in Task{@MainActor in guard let self=self else{return};let key=ObjectIdentifier(c);guard let request=self.connectionRequests[key],self.requestOwners[request]==key else{return};if complete || error != nil || data?.isEmpty==false{self.cancelConnectionRequest(key);c.cancel()}else{self.observeDisconnect(c)}}}}
    private func receive(_ c:NWConnection,id:UUID,data:Data,timeout:DispatchWorkItem){c.receive(minimumIncompleteLength:1,maximumLength:8192){[weak self] chunk,_,complete,error in Task{@MainActor in guard let self=self else{return};var buffer=data;if let chunk=chunk{buffer.append(chunk)};guard buffer.count<=139264 else{self.respond(c,ProtocolFailure("INVALID_ARGUMENT").result,status:413);return}
            if let boundary=buffer.range(of:Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound<=8192,let header=String(data:buffer[..<boundary.lowerBound],encoding:.utf8) else{self.respond(c,ProtocolFailure("INVALID_ARGUMENT").result,status:400);return}
                let lines=header.components(separatedBy:"\r\n"),start=lines[0].split(separator:" ");var headers:[String:String]=[:],valid=true
                for line in lines.dropFirst(){guard let colon=line.firstIndex(of:":") else{valid=false;break};let name=line[..<colon].lowercased(),value=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces);if headers[name] != nil{valid=false;break};headers[name]=value}
                guard valid,start.count==3,start[0]=="POST",start[2]=="HTTP/1.1",headers["transfer-encoding"]==nil,let length=Int(headers["content-length"] ?? "0"),length>=0,length<=131072 else{self.respond(c,ProtocolFailure("INVALID_ARGUMENT").result,status:400);return}
                let body=Data(buffer[boundary.upperBound...]);if body.count>=length {guard body.count==length else{self.respond(c,ProtocolFailure("INVALID_ARGUMENT").result,status:400);return};timeout.cancel();self.handle(c,path:String(start[1]),headers:headers,body:body);return}
            }
            if buffer.range(of:Data("\r\n\r\n".utf8))==nil && buffer.count>8192{timeout.cancel();self.respond(c,ProtocolFailure("INVALID_ARGUMENT").result,status:413);return}
            if complete || error != nil{timeout.cancel();c.cancel();self.connections[id]=nil;return};self.receive(c,id:id,data:buffer,timeout:timeout)
        }}}
    private func authenticate(_ h:[String:String],claim:Bool) throws -> String {
        guard enabled else{throw ProtocolFailure("DISABLED")};guard h["origin"]==nil,h["host"]=="127.0.0.1:\(port)",h["authorization"]=="Bearer \(authorizationNonce)" else{throw ProtocolFailure("NOT_AUTHORIZED")}
        guard !session.suspended else{throw ProtocolFailure("APP_SUSPENDED")};guard session.voiceLease==nil else{throw ProtocolFailure("SESSION_IN_USE")};guard let client=h["x-checkmate-client"],UUID(uuidString:client) != nil else{throw ProtocolFailure("INVALID_ARGUMENT")}
        if let owner=owner{guard owner==client else{throw ProtocolFailure("SESSION_IN_USE")}}else if claim{owner=client;lease=UUID().uuidString;connected=true;status="Connected";session.setConnection(enabled:true,role:configuredRole,lease:lease)}else{throw ProtocolFailure("NOT_CONNECTED")};touched=Date();return lease!
    }
    private func handle(_ c:NWConnection,path:String,headers:[String:String],body:Data){do {
        guard let a=(try? JSONSerialization.jsonObject(with:body)) as? [String:Any] else{throw ProtocolFailure("INVALID_ARGUMENT")};let lease=try authenticate(headers,claim:path=="/rpc")
        switch path {
        case "/heartbeat":respond(c,["ok":true])
        case "/cancel":if let id=a["id"] as? String{pending[id]?.cancel()};respond(c,["ok":true])
        case "/disconnect":release();respond(c,["ok":true])
        case "/rpc":guard let id=a["id"] as? String,UUID(uuidString:id) != nil,let method=a["method"] as? String,tools.schemas.names.contains(method),let args=a["args"] as? [String:Any],Set(a.keys)==Set(["id","method","args"]) else{throw ProtocolFailure("INVALID_ARGUMENT")};guard pending.count<8,pending[id]==nil else{throw ProtocolFailure("BUSY")}
            let key=ObjectIdentifier(c);requestOwners[id]=key
            let task=Task{[weak self] in guard let self=self else{return};defer{if self.requestOwners[id]==key{self.pending[id]=nil;self.requestOwners[id]=nil;self.deadlines.removeValue(forKey:id)?.cancel()};self.connectionRequests.removeValue(forKey:key)};do{let result=try await self.tools.call(method,args:args,lease:lease);try Task.checkCancellation();self.respond(c,result)}catch{self.respond(c,Self.failure(error))}};pending[id]=task
            connectionRequests[key]=id;observeDisconnect(c)
            deadlines[id]=Task{[weak self] in try? await Task.sleep(nanoseconds:UInt64((self?.requestTimeout ?? 25)*1_000_000_000));if !Task.isCancelled{self?.pending[id]?.cancel()}}
        default:throw ProtocolFailure("INVALID_ARGUMENT")
        }
    }catch{respond(c,Self.failure(error),status:400)}}
    public static func failure(_ error:Error)->[String:Any] {if let e=error as? ProtocolFailure{return e.result};if error is CancellationError{return ProtocolFailure("CANCELLED").result};if let e=error as? CheckmateError {switch e{case .stale:return ProtocolFailure("STALE_STATE").result;case .cancelled:return ProtocolFailure("CANCELLED").result;case .invalid(let code):return ProtocolFailure(code.contains(" ") ? "INVALID_MOVE":code).result;case .unavailable(let code):return ProtocolFailure(code.contains(" ") ? "ENGINE_UNAVAILABLE":code).result}};return ProtocolFailure("INTERNAL_ERROR","The request failed. Read the current session and try again.").result}
    private func respond(_ c:NWConnection,_ result:Any,status:Int=200){let data=(try? JSONSerialization.data(withJSONObject:result,options:[.fragmentsAllowed,.sortedKeys])) ?? Data("{}".utf8);var reply=Data("HTTP/1.1 \(status) \(status==200 ? "OK":"Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8);reply.append(data);c.send(content:reply,completion:.contentProcessed{_ in c.cancel()})}
}
