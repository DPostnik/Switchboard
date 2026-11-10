import Foundation

public enum ProjectRelocation: Equatable, Sendable {
    case moved
    /// The chats joined the project that already had the new folder.
    case merged(into: UUID)
}

extension SavedState {
    public var visibleProjects: [Project] { projects.filter { !$0.isHidden } }
    /// Projects the user hid and can show again; deleted ones are only reached through the archive.
    public var hiddenProjects: [Project] { projects.filter { $0.isHidden && !$0.isRemoved } }

    public var visiblePinnedChats: [Chat] {
        let visibleIDs = Set(visibleProjects.map(\.id))
        return chats.filter { $0.isPinned && !$0.isArchived && visibleIDs.contains($0.projectID) }
    }

    @discardableResult public mutating func hideProject(_ id: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }), !projects[index].isHidden else { return false }
        projects[index].hidden = true
        return true
    }

    /// Brings a hidden project back to the sidebar with its chats, name and settings.
    @discardableResult public mutating func showProject(_ id: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }), projects[index].isHidden else { return false }
        projects[index].hidden = nil
        projects[index].removed = nil
        return true
    }

    /// Marks a project deleted after its chats went to the archive (`DeskModel.deleteProject`).
    @discardableResult public mutating func removeProject(_ id: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }), !projects[index].isRemoved else { return false }
        projects[index].hidden = true
        projects[index].removed = true
        return true
    }

    /// Points a project at its moved folder. When another project already has that folder, the chats and queued
    /// messages move to it and this record goes; otherwise the path changes, and a name that was the old folder's name
    /// follows the new one. Either way the resulting project is shown. Nil when nothing changes.
    public mutating func relocateProject(_ id: UUID, to path: String) -> ProjectRelocation? {
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        let target = canonical(path)
        guard let index = projects.firstIndex(where: { $0.id == id }), canonical(projects[index].path) != target else { return nil }
        if let other = projects.firstIndex(where: { $0.id != id && canonical($0.path) == target }) {
            let into = projects[other].id
            for chat in chats.indices where chats[chat].projectID == id { chats[chat].projectID = into }
            queuedMessages = queuedMessages?.map { message in
                var message = message
                if message.projectID == id { message.projectID = into }
                return message
            }
            projects[other].hidden = nil
            projects[other].removed = nil
            projects.remove(at: index)
            return .merged(into: into)
        }
        if projects[index].name == URL(fileURLWithPath: projects[index].path).lastPathComponent {
            projects[index].name = URL(fileURLWithPath: target).lastPathComponent
        }
        projects[index].path = target
        projects[index].hidden = nil
        projects[index].removed = nil
        return .moved
    }

    /// Display name only; the folder is never touched. An empty name restores the folder name.
    @discardableResult public mutating func renameProject(_ id: UUID, to name: String) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? URL(fileURLWithPath: projects[index].path).lastPathComponent : trimmed
        guard projects[index].name != resolved else { return false }
        projects[index].name = resolved
        return true
    }

    /// Re-adding a folder restores the same project, including its chat and job identities.
    @discardableResult public mutating func addProject(path: String) -> UUID {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if let index = projects.firstIndex(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == canonicalPath
        }) {
            projects[index].hidden = nil
            projects[index].removed = nil
            return projects[index].id
        }
        let project = Project(path: canonicalPath)
        projects.append(project)
        return project.id
    }
}
