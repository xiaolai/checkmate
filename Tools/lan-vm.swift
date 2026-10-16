// LAN-play spike (e): a macOS virtual machine on a test host (Virtualization.framework), to run the spike's probes on
// an older macOS. Build with Tools/lan-vm.sh, which signs it with the virtualization entitlement.
//   lan-vm install <restore.ipsw> <bundle-dir> [disk-gigabytes]   create the machine and install macOS from the image
//   lan-vm run <bundle-dir> <shared-dir>                           boot it in a window; <shared-dir> appears in the guest
//                                                                  as /Volumes/My Shared Files/spike
// The window is a real one on the host's console, so the guest's Setup Assistant and Terminal take the host's real
// pointer and key events; the guest has no SSH or other back door.
import AppKit
import Foundation
import Virtualization

// The test host carries ~/.config/checkmate/host-role naming "test" (alone or with "build"), the marker scripts/test_host.py reads.
let hostRoles=Set(((try? String(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/checkmate/host-role"),encoding:.utf8)) ?? "").split(whereSeparator:\.isWhitespace).map(String.init))
guard hostRoles.contains("test") else{fatalError("lan-vm runs on a test host only.")}

let arguments=CommandLine.arguments
func fail(_ message:String)->Never {FileHandle.standardError.write(Data((message+"\n").utf8));exit(1)}
guard arguments.count>=4 || (arguments.count>=3 && arguments[1]=="run") else{fail("Usage: lan-vm install <ipsw> <bundle> [gigabytes] | run <bundle> <shared>")}
// The machine's files, for `run` (install names its own target).
let bundle=URL(fileURLWithPath:arguments[2])
let disk=bundle.appendingPathComponent("disk.img"),auxiliary=bundle.appendingPathComponent("auxiliary"),hardware=bundle.appendingPathComponent("hardware-model"),machine=bundle.appendingPathComponent("machine-identifier")
// The CPUs and memory chosen at install (the image's minimums, or more), so every boot gets what the system needs.
let resourcesFile=bundle.appendingPathComponent("resources.json")
func savedResources()->(cpus:Int,memory:UInt64)? {
    guard let data=try? Data(contentsOf:resourcesFile),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let cpus=object["cpus"] as? Int,let memory=object["memory"] as? NSNumber else{return nil}
    return (cpus,memory.uint64Value)
}

func configuration(model:VZMacHardwareModel,identifier:VZMacMachineIdentifier,shared:URL?)throws -> VZVirtualMachineConfiguration {
    let platform=VZMacPlatformConfiguration();platform.hardwareModel=model;platform.machineIdentifier=identifier
    platform.auxiliaryStorage=VZMacAuxiliaryStorage(url:auxiliary)
    let config=VZVirtualMachineConfiguration();config.platform=platform;config.bootLoader=VZMacOSBootLoader()
    let resources=savedResources() ?? (min(4,ProcessInfo.processInfo.processorCount-2),6*1024*1024*1024)
    config.cpuCount=resources.cpus;config.memorySize=resources.memory
    let graphics=VZMacGraphicsDeviceConfiguration();graphics.displays=[VZMacGraphicsDisplayConfiguration(widthInPixels:1920,heightInPixels:1200,pixelsPerInch:110)];config.graphicsDevices=[graphics]
    config.storageDevices=[VZVirtioBlockDeviceConfiguration(attachment:try VZDiskImageStorageDeviceAttachment(url:disk,readOnly:false))]
    let network=VZVirtioNetworkDeviceConfiguration();network.attachment=VZNATNetworkDeviceAttachment();config.networkDevices=[network]
    config.pointingDevices=[VZUSBScreenCoordinatePointingDeviceConfiguration()];config.keyboards=[VZUSBKeyboardConfiguration()]
    if let shared {
        let share=VZVirtioFileSystemDeviceConfiguration(tag:VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        share.share=VZMultipleDirectoryShare(directories:["spike":VZSharedDirectory(url:shared,readOnly:false)]);config.directorySharingDevices=[share]
    }
    try config.validate();return config
}

final class Delegate:NSObject,NSApplicationDelegate,VZVirtualMachineDelegate {
    var machineRef:VZVirtualMachine?,window:NSWindow?,installer:VZMacOSInstaller?,observation:NSKeyValueObservation?
    func applicationDidFinishLaunching(_ notification:Notification){
        switch arguments[1] {
        case "install":install()
        case "run":run()
        default:fail("Unknown command \(arguments[1])")
        }
    }
    func install(){
        let ipsw=URL(fileURLWithPath:arguments[2]),target=URL(fileURLWithPath:arguments[3])
        let gigabytes=UInt64(arguments.count>4 ? arguments[4]:"48") ?? 48
        VZMacOSRestoreImage.load(from:ipsw){result in DispatchQueue.main.async{
            do {
                let restore=try result.get()
                guard let requirements=restore.mostFeaturefulSupportedConfiguration else{fail("This host cannot run \(restore.operatingSystemVersion)")}
                try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
                let auxiliary=target.appendingPathComponent("auxiliary"),disk=target.appendingPathComponent("disk.img")
                guard !FileManager.default.fileExists(atPath:disk.path) else{fail("\(target.path) already holds a machine")}
                try requirements.hardwareModel.dataRepresentation.write(to:target.appendingPathComponent("hardware-model"))
                let identifier=VZMacMachineIdentifier();try identifier.dataRepresentation.write(to:target.appendingPathComponent("machine-identifier"))
                _ = try VZMacAuxiliaryStorage(creatingStorageAt:auxiliary,hardwareModel:requirements.hardwareModel,options:[])
                guard FileManager.default.createFile(atPath:disk.path,contents:nil) else{fail("Cannot create the disk")}
                let handle=try FileHandle(forWritingTo:disk);try handle.truncate(atOffset:gigabytes*1024*1024*1024);try handle.close()
                let platform=VZMacPlatformConfiguration();platform.hardwareModel=requirements.hardwareModel;platform.machineIdentifier=identifier;platform.auxiliaryStorage=VZMacAuxiliaryStorage(url:auxiliary)
                let config=VZVirtualMachineConfiguration();config.platform=platform;config.bootLoader=VZMacOSBootLoader()
                config.cpuCount=max(requirements.minimumSupportedCPUCount,4);config.memorySize=max(requirements.minimumSupportedMemorySize,6*1024*1024*1024)
                try JSONSerialization.data(withJSONObject:["cpus":config.cpuCount,"memory":config.memorySize]).write(to:target.appendingPathComponent("resources.json"))
                let graphics=VZMacGraphicsDeviceConfiguration();graphics.displays=[VZMacGraphicsDisplayConfiguration(widthInPixels:1920,heightInPixels:1200,pixelsPerInch:110)];config.graphicsDevices=[graphics]
                config.storageDevices=[VZVirtioBlockDeviceConfiguration(attachment:try VZDiskImageStorageDeviceAttachment(url:disk,readOnly:false))]
                try config.validate()
                let vm=VZVirtualMachine(configuration:config);self.machineRef=vm
                let installer=VZMacOSInstaller(virtualMachine:vm,restoringFromImageAt:ipsw);self.installer=installer
                print("Installing \(restore.operatingSystemVersion.majorVersion).\(restore.operatingSystemVersion.minorVersion) build \(restore.buildVersion)");fflush(stdout)
                self.observation=installer.progress.observe(\.fractionCompleted,options:[.new]){progress,_ in print(String(format:"progress %.0f%%",progress.fractionCompleted*100));fflush(stdout)}
                installer.install{outcome in DispatchQueue.main.async{
                    switch outcome {case .success:print("installed");exit(0);case .failure(let error):fail("Install failed: \(error)")}
                }}
            } catch {fail("Install setup failed: \(error)")}
        }}
    }
    func run(){
        guard arguments.count>=4 else{fail("run needs <bundle> <shared>")}
        do {
            guard let model=VZMacHardwareModel(dataRepresentation:try Data(contentsOf:hardware)),let identifier=VZMacMachineIdentifier(dataRepresentation:try Data(contentsOf:machine)) else{fail("Unreadable machine files")}
            let vm=VZVirtualMachine(configuration:try configuration(model:model,identifier:identifier,shared:URL(fileURLWithPath:arguments[3])));vm.delegate=self;machineRef=vm
            let view=VZVirtualMachineView();view.virtualMachine=vm;view.capturesSystemKeys=true
            if #available(macOS 14.0,*){view.automaticallyReconfiguresDisplay=false}
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:800),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
            window.title="lan-vm \(bundle.lastPathComponent)";window.contentView=view;window.center();window.makeKeyAndOrderFront(nil);self.window=window
            NSApp.activate(ignoringOtherApps:true)
            vm.start{result in if case .failure(let error)=result{fail("Start failed: \(error)")};print("running");fflush(stdout)}
        } catch {fail("Run failed: \(error)")}
    }
    func guestDidStop(_ virtualMachine:VZVirtualMachine){print("stopped");exit(0)}
    func virtualMachine(_ virtualMachine:VZVirtualMachine,didStopWithError error:Error){fail("Stopped with error: \(error)")}
}
let application=NSApplication.shared
let delegate=Delegate()
application.delegate=delegate
application.setActivationPolicy(arguments[1]=="run" ? .regular:.prohibited)
application.run()
