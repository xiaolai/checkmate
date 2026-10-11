import XCTest
@testable import CheckmateCore

private final class RecordingSocketFixture:LessonRecordingSocket,@unchecked Sendable {
 private let lock=NSLock()
 private var events:[Data]
 private var stopped=false
 private var outgoing:[Data]=[]
 init(_ events:[[String:Any]]){self.events=events.map{try! JSONSerialization.data(withJSONObject:$0)}}
 init(raw:Data){events=[raw]}
 private func next()throws->Data? {lock.lock();defer{lock.unlock()};if stopped{throw CancellationError()};return events.isEmpty ? nil:events.removeFirst()}
 func send(_ data:Data)async throws {append(data)}
 private func append(_ data:Data){lock.lock();outgoing.append(data);lock.unlock()}
 func receive()async throws->Data {while true{if let data=try next(){return data};try await Task.sleep(for:.milliseconds(1))}}
 func close(){lock.lock();stopped=true;lock.unlock()}
 var closed:Bool {lock.lock();defer{lock.unlock()};return stopped}
 var sent:[Data]{lock.lock();defer{lock.unlock()};return outgoing}
}
private final class RecordingUsageFixture:@unchecked Sendable {
 private let lock=NSLock();private var values:[(String,UsageTokens?)]=[]
 func add(_ id:String,_ tokens:UsageTokens?){lock.lock();values.append((id,tokens));lock.unlock()}
 var count:Int {lock.lock();defer{lock.unlock()};return values.count}
 var total:Int64? {lock.lock();defer{lock.unlock()};return values.first?.1?.total}
}
final class LessonRecordingTests:XCTestCase {
 private func start(model:String="gpt-realtime")->[[String:Any]] {[["type":"session.updated","session":["model":model]],["type":"response.created","response":["id":"r"]]]}
 private func done(status:String="completed",id:String="r")->[String:Any] {["type":"response.done","response":["id":id,"status":status,"usage":["total_tokens":19]]]}
 private func audio(_ count:Int=48,id:String="r")->[String:Any] {["type":"response.output_audio.delta","response_id":id,"delta":Data(repeating:0,count:count).base64EncodedString()]}
 private func transcript(_ text:String="Hello.")->[String:Any] {["type":"response.output_audio_transcript.done","response_id":"r","transcript":text]}
 private func recorder(_ socket:RecordingSocketFixture,timeout:Double=1)->RealtimeLessonRecorder {RealtimeLessonRecorder(timeout:timeout,secretProvider:{"fixture-secret"},socketFactory:{_ in socket})}
 func testSuccessfulRecorderHasNoInputCaptureAndCloses()async throws {
  let socket=RecordingSocketFixture(start()+[audio(),transcript(),done()]),usage=RecordingUsageFixture()
  let result=try await recorder(socket).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:usage.add)
  XCTAssertEqual(result.pcm.count,48);XCTAssertEqual(usage.total,19);XCTAssertTrue(socket.closed)
  let packets=try socket.sent.map{try JSONSerialization.jsonObject(with:$0) as! [String:Any]}
  XCTAssertEqual(packets.count,2);XCTAssertFalse(packets.contains{($0["type"] as? String ?? "").contains("input_audio_buffer")})
  let session=packets[0]["session"] as! [String:Any];XCTAssertTrue((session["tools"] as! [Any]).isEmpty);XCTAssertEqual(session["tool_choice"] as? String,"none")
 }
 func testFailedCancelledAndInvalidFinalCaptureUsage()async {
  for status in ["failed","cancelled","completed"] {
   let socket=RecordingSocketFixture(start()+[done(status:status)]),usage=RecordingUsageFixture()
   do{_=try await recorder(socket).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:usage.add);XCTFail("Expected invalid response")}catch{}
   XCTAssertEqual(usage.count,1);XCTAssertEqual(usage.total,19);XCTAssertTrue(socket.closed)
  }
 }
 func testTranscriptMismatchPreservesDeliveredUsage()async {
  let socket=RecordingSocketFixture(start()+[audio(),transcript("Different text."),done()]),usage=RecordingUsageFixture()
  do{_=try await recorder(socket).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:usage.add);XCTFail("Expected mismatch")}catch{}
  XCTAssertEqual(usage.total,19);XCTAssertTrue(socket.closed)
 }
 func testRejectToolsOddPCMTranscriptBoundsAndForeignResponse()async {
  let cases:[[String:Any]]=[["type":"response.function_call_arguments.done"],audio(3),transcript(String(repeating:"x",count:LessonRecording.maximumTranscriptBytes+1)),audio(id:"foreign")]
  for event in cases {
   let socket=RecordingSocketFixture(start()+[event])
   do{_=try await recorder(socket).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:{_,_ in});XCTFail("Expected rejected event")}catch{}
   XCTAssertTrue(socket.closed)
  }
 }
 func testRejectMismatchedFinalIDAndUnsupportedModel()async {
  for events in [start()+[audio(),transcript(),done(id:"other")],start(model:"gpt-realtime-mini")] {
   let socket=RecordingSocketFixture(events)
   do{_=try await recorder(socket).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:{_,_ in});XCTFail("Expected rejected response")}catch{}
   XCTAssertTrue(socket.closed)
  }
  XCTAssertTrue(LessonRecording.acceptedModel("gpt-realtime-2025-08-28"));XCTAssertFalse(LessonRecording.acceptedModel("gpt-realtime-preview"))
 }
 func testMessageCapAndPCMAggregateCap()async {
  let oversized=RecordingSocketFixture(raw:Data(repeating:0,count:LessonRecording.maximumMessageBytes+1))
  do{_=try await recorder(oversized).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:{_,_ in});XCTFail("Expected size rejection")}catch{}
  XCTAssertTrue(oversized.closed)
  let chunk=audio(1_000_000),socket=RecordingSocketFixture(start()+Array(repeating:chunk,count:29))
  do{_=try await recorder(socket,timeout:10).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:{_,_ in});XCTFail("Expected PCM rejection")}catch{XCTAssertTrue(String(describing:error).contains("too long"))}
  XCTAssertTrue(socket.closed)
 }
 func testTimeoutAndCancellationCleanup()async {
  let socket=RecordingSocketFixture([]),begin=Date()
  do{_=try await recorder(socket,timeout:0.02).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:{_,_ in});XCTFail("Expected timeout")}catch{XCTAssertTrue(String(describing:error).contains("timed out"))}
  XCTAssertTrue(socket.closed);XCTAssertLessThan(Date().timeIntervalSince(begin),1)
  let cancelled=RecordingSocketFixture([]),task=Task{try await recorder(cancelled).record(script:"Hello.",locale:"en",voice:"cedar",onUsage:{_,_ in})}
  try? await Task.sleep(for:.milliseconds(5));task.cancel()
  do{_=try await task.value;XCTFail("Expected cancellation")}catch{XCTAssertTrue(error is CancellationError)}
  XCTAssertTrue(cancelled.closed)
 }
 func testLiveRecorderIsDisabledInAutomation()async {
  do{_=try await RealtimeLessonRecorder().record(script:"Hello.",locale:"en",voice:"cedar",onUsage:{_,_ in});XCTFail("Expected disabled live transport")}catch{XCTAssertTrue(String(describing:error).contains("automation"))}
 }
 func testRedirectDelegateRefusesRedirect() {
  let gateway=VoiceGateway(),session=URLSession(configuration:.ephemeral),task=session.dataTask(with:URL(string:"https://api.openai.com")!)
  defer{session.invalidateAndCancel()}
  let response=HTTPURLResponse(url:URL(string:"https://api.openai.com")!,statusCode:302,httpVersion:nil,headerFields:nil)!
  var accepted=true
  gateway.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"https://example.invalid")!)){accepted=$0 != nil}
  XCTAssertFalse(accepted)
 }
}
