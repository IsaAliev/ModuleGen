import XcodeProj
import ArgumentParser
import PathKit
import Foundation

class GenerationInput: Codable, CustomStringConvertible {
    class Folder: Codable, CustomStringConvertible {
        class File: Codable {
            let templateId: String
            let name: String
            let parameters: [String: String]?
            
            init(templateId: String, name: String, parameters: [String : String]?) {
                self.name = name
                self.templateId = templateId
                self.parameters = parameters
            }
        }
        
        let name: String
        var files: [File]?
        var folders: [Folder]?
        
        var description: String {
            "Folder:\(name)\n" +
                "Files:\(files?.map({ $0.templateId }).joined(separator: ", "))\n" +
                "SubFolders: \(folders?.compactMap({ $0.description }))\n"
        }
        
        init(name: String, files: [GenerationInput.Folder.File]?, folders: [GenerationInput.Folder]?) {
            self.name = name
            self.files = files
            self.folders = folders
        }
    }
    
    var description: String {
        folders.map({ $0.description }).joined(separator: "\n")
    }
    
    var folders = [Folder]()
}

private let fileManager = FileManager.default

final class ModuleGen: ParsableCommand {
    lazy var sourceRoot = Path(URL(fileURLWithPath: projectPath).deletingLastPathComponent().path)
    lazy var path = Path(projectPath)
    lazy var proj = try! XcodeProj(path: path)
    
    @Argument(help: "Project path")
    var projectPath: String
    
    @Argument(help: "Target path")
    var targetPath: String
    
    @Argument(help: "Templates path")
    var templatesPath: String
    
    @Argument(help: "JSON template path")
    var inputFilePath: String
    
    private var input: GenerationInput!
    
    @Option(help: "Parameters", transform: {
        guard let data = $0.data(using: .utf8) else { return [:] }
        
        return try! JSONDecoder().decode([String: String].self, from: data)
    })
    var parameters: [String: String]?
    
    func run() throws {
        try generateFilesAndFolders()
    }
    
    private func generateFilesAndFolders() throws {
        print("Parsing input ...")
        try parseInput()

        let projectDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path

        print("Generating files and folders ...")
        for folder in input.folders {
            try generateFolder(folder, at: projectDir + "/" + targetPath)
        }

        print("Modifying XCode Project ...")
        try modifyXcodeProj()

        print("Done")
    }
    
    private func parseInput() throws {
        func paramsFrom(line: String) -> [String: String]? {
            guard let paramsString = line.split(separator: "-").last?.trimmingCharacters(in: .whitespaces),
                  let data = paramsString.data(using: .utf8) else {
                return nil
            }
            
            return try? JSONDecoder().decode([String: String].self, from: data)
        }
        
        func templateId(from line: String) -> String {
            let paramRegex = try! NSRegularExpression(pattern: "\\[.*]", options: [])
            guard let match = paramRegex.firstMatch(in: line, options: [], range: NSMakeRange(0, line.count)) else {
                return ""
            }
            
            return NSString(string: line).substring(with: match.range)
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
        }
        
        func fileNameFrom(line: String) -> String {
            let left = line.split(separator: "-").first!.trimmingCharacters(in: .whitespaces)
            
            return left.replacingOccurrences(of: "[\(templateId(from: left))]", with: "")
        }
        
        let url = URL(fileURLWithPath: inputFilePath)
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return }
        
        let lines = content.split(separator: "\n").map(String.init)
        let input = GenerationInput()
        var levels = [Int: [GenerationInput.Folder]]()
        let tabRegex = try! NSRegularExpression(pattern: "\\t", options: [])
        
        for line in lines {
            let currentLevel = tabRegex.matches(in: line, options: [], range: NSMakeRange(0, line.count)).count
            let isFolder = line.hasSuffix(":")
            let rawLine = line.trimmingCharacters(in: .whitespaces)
            let name = isFolder ? String(rawLine.dropLast()) : fileNameFrom(line: rawLine)
            
            if isFolder {
                let folder = GenerationInput.Folder(name: name, files: [], folders: [])
                let parentFolderLevel = currentLevel - 1
                
                if var folders = levels[currentLevel] {
                    folders.append(folder)
                } else {
                    levels[currentLevel] = [folder]
                }
                
                if parentFolderLevel < 0 {
                    input.folders.append(folder)
                    
                } else {
                    levels[parentFolderLevel]?.last?.folders?.append(folder)
                }
            } else {
                let file = GenerationInput.Folder.File(
                    templateId: templateId(from: line),
                    name: fileNameFrom(line: line),
                    parameters: paramsFrom(line: rawLine)
                )
                let parentFolderLevel = currentLevel - 1
                
                levels[parentFolderLevel]?.last?.files?.append(file)
            }
        }
        
        self.input = input
    }
    
    private func modifyXcodeProj() throws {
        let pathComps = targetPath.split(separator: "/").map(String.init)
        var targetGroup = proj.pbxproj.groups.filter({ $0.path == pathComps[0] }).first
        
        for pathElement in pathComps.dropFirst() {
            targetGroup = targetGroup?.children.compactMap({ $0 as? PBXGroup }).filter({ $0.path == pathElement }).first
        }
        
        guard let group = targetGroup else { return }
        
        for folder in input.folders {
           try bindFolder(folder, and: group)
        }
        
        try proj.write(path: path)
    }
    
    private func bindFolder(_ folder: GenerationInput.Folder, and group: PBXGroup) throws {
        guard let currentPath = try group.fullPath(sourceRoot: sourceRoot) else { return }
        guard let group = try group.addGroup(named: complete(folder.name)).first else { return }
        
        for folder in folder.folders ?? [] {
            try bindFolder(folder, and: group)
        }
        
        for file in folder.files ?? [] {
            let filePath = currentPath.string + "/"
                + (try complete(folder.name)) + "/"
                + cleanFileName(try complete(file.name, parameters: file.parameters ?? [:]))
            
            try group.addFile(at: .init(filePath), sourceRoot: sourceRoot)
        }
    }
    
    private func generateFolder(_ folder: GenerationInput.Folder, at path: String) throws {
        let currentDir = try complete(path + folder.name, parameters: [:])
        
        print("Creating folder: \(currentDir)")
        try fileManager.createDirectory(
            at: .init(fileURLWithPath: currentDir),
            withIntermediateDirectories: false,
            attributes: nil
        )
        
        for file in folder.files ?? [] {
            guard let content = try! generateContent(for: file) else { return }
            var fileName = try complete(file.name, parameters: file.parameters ?? [:])
            fileName = cleanFileName(fileName)
            
            let contentData = content.data(using: .utf8)
            
            try contentData?.write(to: .init(fileURLWithPath: currentDir + "/" + fileName))
        }
        
        guard let folders = folder.folders else { return }
        
        for f in folders {
            try generateFolder(f, at: path + folder.name + "/")
        }
    }
    
    private func cleanFileName(_ name: String) -> String {
        (name as NSString)
            .replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression, range: NSRange(location: 0, length: name.count))
    }
    
    private func generateContent(for file: GenerationInput.Folder.File) throws -> String? {
        let contentPath = templatesPath + file.templateId
        print("Creating file from template: \(contentPath)")
        let contentData = try Data(contentsOf: .init(fileURLWithPath: contentPath))
        guard let content = String(data: contentData, encoding: .utf8) else { return nil }
        
        return try complete(content, parameters: file.parameters ?? [:])
    }
    
    private func complete(_ template: String, parameters: [String: String] = [:]) throws -> String {
        let paramRegex = try NSRegularExpression(pattern: "___[^\\s]+___", options: [])
        let matches = paramRegex.matches(in: template, options: [], range: NSMakeRange(0, template.count))
        var result = NSString(string: template)
        
        for match in matches.reversed() {
            let range = match.range
            let param = NSString(string: template).substring(with: range)
            let paramKey = String(param.dropFirst(3).dropLast(3))
            guard let val = parameters[paramKey] ?? self.parameters?[paramKey] else { continue }
            
            result = result.replacingCharacters(in: range, with: val) as NSString
        }
        
        return result as String
    }
}

ModuleGen.main()
