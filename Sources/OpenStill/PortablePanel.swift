import AppKit
import UniformTypeIdentifiers
import OpenStillCore

extension ViewerController {
    @objc func exportEditPackage(){
        guard let source=currentSource,let record=photoRecord,let window=view.window else{return}
        let panel=NSSavePanel();panel.title="Export portable edits";panel.nameFieldStringValue=source.deletingPathExtension().lastPathComponent+".openstilledits";panel.allowedContentTypes=[UTType(exportedAs:"org.openstill.edit-package",conformingTo:.package)]
        let include=NSButton(checkboxWithTitle:"Include a copy of the original photograph",target:nil,action:nil)
        panel.accessoryView=include;panel.message="Includes all versions, history, ratings, masks, and referenced LUT/image assets. Without an original, import requires verified relinking."
        panel.beginSheetModal(for:window){[weak self] response in
            guard let self,response == .OK,let destination=panel.url else{return};let includeOriginal=include.state == .on
            self.info.status("Packaging edit versions…")
            DispatchQueue.global(qos:.userInitiated).async {
                let result=Result{try PortableEdits.export(record:record,source:source,to:destination,includeOriginal:includeOriginal)}
                DispatchQueue.main.async{switch result{case .success:self.info.status("Saved portable edits · "+destination.lastPathComponent);case .failure(let error):self.info.status(error.localizedDescription)}}
            }
        }
    }
    @objc func importEditPackage(){
        guard let window=view.window else{return}
        let panel=NSOpenPanel();panel.title="Import portable edits";panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.treatsFilePackagesAsDirectories=false;panel.allowedContentTypes=[UTType(exportedAs:"org.openstill.edit-package",conformingTo:.package)]
        panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let folder=panel.url else{return};self.inspectPackage(folder)}
    }
    func inspectPackage(_ folder:URL){
        info.status("Verifying portable edits and asset checksums…")
        DispatchQueue.global(qos:.userInitiated).async{[weak self] in
            let result=Result{try PortableEdits.inspect(folder)}
            DispatchQueue.main.async{guard let self else{return};switch result{case .success(let package):
                if package.original != nil{self.finishPackageImport(folder,relink:nil)}
                else if let window=self.view.window{let picker=NSOpenPanel();picker.title="Relink original photograph";picker.message="Select \(package.record.sourcePath). Its contents must match the original checksum; filenames alone are never used.";picker.canChooseDirectories=false;picker.beginSheetModal(for:window){response in guard response == .OK,let url=picker.url else{return};self.finishPackageImport(folder,relink:url)}}
            case .failure(let error):self.packageError(error)}}
        }
    }
    private func finishPackageImport(_ folder:URL,relink:URL?){
        DispatchQueue.global(qos:.userInitiated).async{[weak self] in let result=Result{try PortableEdits.importPackage(folder,relink:relink)};DispatchQueue.main.async{guard let self else{return};switch result{case .success(let record):self.open([URL(fileURLWithPath:record.sourcePath)]);self.info.status("Imported as new versions. Existing edits are preserved.");case .failure(let error):self.packageError(error)}}}
    }
    private func packageError(_ error:Error){info.status(error.localizedDescription);if let window=view.window{let alert=NSAlert();alert.messageText="Couldn’t import portable edits";alert.informativeText=error.localizedDescription;alert.beginSheetModal(for:window)}}
}
