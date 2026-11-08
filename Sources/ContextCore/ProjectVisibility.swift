import Foundation

extension SavedState {
    public var visibleProjects: [Project] { projects.filter { !$0.isHidden } }

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
        return true
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
            return projects[index].id
        }
        let project = Project(path: canonicalPath)
        projects.append(project)
        return project.id
    }
}
