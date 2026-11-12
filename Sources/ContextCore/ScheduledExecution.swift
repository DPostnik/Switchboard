import Foundation
import AgentContract

extension ManagedJob {
    /// The job's own role, capped at the project's job default: a job never runs with more than the project allows.
    public func role(project: Project, catalog: AgentRoleCatalog) -> AgentRole {
        let projectRole = project.jobRole(catalog)
        guard let own = catalog.role(roleID), own.rank <= projectRole.rank else { return projectRole }
        return own
    }
    /// `sharedRoots` are the folders for every project as the user set them (`SavedState.sharedRoots`).
    public func executionRequest(runID: UUID, project: Project, descriptor: AgentDescriptor, catalog: AgentRoleCatalog = AgentRoleCatalog(),
                                 sharedRoots: [AgentPermissionProfile.Root] = []) -> AgentExecutionRequest {
        let permissions: AgentPermissionIntent
        let role = role(project: project, catalog: catalog)
        if descriptor.identityMode == .externalCLI, acceptsExternalPolicy == true, role.legacyAccessMode == .fullAccess {
            permissions = .externalPolicyDenyPrompts
        } else {
            permissions = .profile(role.profile(for: project, sharedRoots: sharedRoots), root: project.path)
        }
        // Legacy direct means no app optimizer. External CLI routing is explicitly disclosed.
        let route: AgentRoute = descriptor.identityMode == .externalCLI && self.route == .direct
            ? .externalConfiguration : self.route.agentRoute
        return AgentExecutionRequest(id: runID, conversation: ConversationID(), kind: .scheduled,
            prompt: prompt, projectPath: project.path, permissions: permissions,
            model: .init(context: descriptor.context, model: model, effort: effort), route: route)
    }
}

extension JobRunStatus {
    public init(_ outcome: AgentExecutionOutcome) {
        switch outcome {
        case .completed: self = .completed
        case .failed: self = .failed
        case .blocked: self = .blocked
        case .cancelled: self = .interrupted
        case .uncertain: self = .uncertain
        }
    }
}
